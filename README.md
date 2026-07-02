# kernelsmith

A Nix-based universal Linux kernel cross-compiler: build essentially **any kernel
version (2.6 → current 6.x)** across **~12 architectures** (arm/armhf/arm64,
mips/mipsel/mips64 big+little endian, powerpc/ppcle/ppc64/ppc64le, x86_64), with the
**right toolchain selected automatically per kernel version**.

This is the foundation under nixifying the rehosting `linux_builder` and `igloo_driver`
flows, and a successor to the hand-maintained `embedded-toolchains` Docker image (a pile
of unpinned `wget`s of musl.cc / panda.re prebuilt toolchains).

## Idea in one picture

```
kernel version ──resolve──► era ──► (arch, gcc-band) cell ──► toolchain
   "3.18.140"      k3          gcc 6.5 / mipsel      cross-mipsel-...-gcc
```

The "single environment" is **not** a baked image holding every toolchain — it's a
resolver + dev shell. Nix laziness realizes only the cell you target; a binary cache
makes any cell you've built before an instant substitution. So you flip between kernel
versions as build targets without rebuilding anything you've seen.

## Layout

| File | Role |
|------|------|
| `flake.nix` | inputs + outputs: the era×arch toolchain matrix, `buildKernel`, `toolchainFor`, a dev shell with `kbuild <ver> <arch>` |
| `resolve.nix` | `kernelVersion → era` via version bands (the gcc-floor dispatch) — **sourcing-agnostic** |
| `matrix.nix` | the data: kernel eras (gcc/binutils/musl bundles) × 12 arch triples + per-arch quirks |
| `mk-cross-toolchain.nix` | builds one (arch, versions) toolchain |
| `sources.nix` | pinned component / toolchain inputs |
| `kernel.nix` | `buildKernel { version, arch, src, config }` — auto-resolves the toolchain |

## Status: full matrix building — Bootlin bands pinned + from-source matrix filled

`nix build .#bootlin-all` builds every pinned Bootlin cell (25); each runs a `-dumpmachine`
install-check, and spot-compiles produce correct per-arch ELF (verified ARM/AArch64/PPC64LE/MIPS).
`toolchainFor`/`buildKernel` now resolve to the Bootlin cell where pinned, else the
musl-cross-make fallback — verified: `5.10/mipsel`→Bootlin k4, `2.6.31/armel`→musl-cross-make k2.6.

Pinned Bootlin cells (gcc per the release inside, not the release year):

| Band (kernel) | gcc | arches covered by Bootlin |
|---|---|---|
| k6 (6.x) | 13.3.0 (2024.05) | all 9 |
| k4 (4.x/5.x) | 9.3.0 (2020.08); x86_64 = 10.3.0 (2021.11, no older musl) | all 9 |
| k3 (3.x) | 6.4.0 (2018.02) | 7 — **powerpc, x86_64 deferred** (no gcc-6 musl: their musl starts 2020.08 / 2021.11) |

**From-source (musl-cross-make) path PROVEN:** `nix build .#spike` builds a k2.6 armel
toolchain (gcc 5.3.0) that compiles static + dynamic-musl ARM ELF. Findings from the spike:
- gcc **4.2.1 / 4.7.4 fail** — mcm-master's `litecross` passes `AR_FOR_TARGET=…` as configure
  args, which pre-modern autoconf rejects. True gcc-4.x needs a **stable/older mcm pin** (TODO).
- mcm master ships **2026 musl CVE patches that corrupt musl-1.1.24 `qsort.c`**;
  `mk-cross-toolchain.nix` strips `patches/musl-*/cve-*.diff`.
- gcc **5.3.0** is the oldest gcc that builds here; above the era-ideal for true 2.6 (upper-bound
  risk) — **now validated**: builds a real 2.6.31 ARM kernel with three documented era quirks (below).

**From-source matrix FILLED (2026-06-29):**
- `nix build .#k26-all` — **all 12 k2.6 cells** build under gcc 5.3.0 (the band Bootlin can't
  supply). Spot-compiles confirm correct per-arch ELF, *including* the 3 arches Bootlin lacks at
  any band: powerpcle (32-bit PPC-LE), mips64eb, mips64el.
- `nix build .#fromsource-extra` — the **Bootlin-uncovered modern cells**: mips64eb/el + powerpcle
  at k3/k4/k6, plus powerpc/x86_64 at k3 (11 cells). gcc 6.5.0 (k3) / 9.4.0 (k4) / 13.3.0 (k6).
- All mcm component versions are reconciled to musl-cross-make's blessed `hashes/` set (it refuses
  to build a version it has no `.sha1` for). So the from-source band now has zero placeholder hashes.

**Decision (2026-06-29): VALIDATED — gcc 5.3.0 is viable for k2.6.** `nix-build
validate-k26.nix` builds a stock **kernel.org 2.6.31** ARM `vmlinux`
end-to-end via `buildKernel`, with the gcc 5.3.0 toolchain auto-resolved from the version.
Output: `ELF 32-bit LSB executable, ARM, statically linked` (3.8 MB). True gcc-4.x / a
stable-mcm pin is **not needed** — the gcc-5-on-2.6 breakage is all known, shimmable upper-bound
stuff, now handled in `kernel.nix`'s k2.6 `eraQuirks`/`postPatch`:
- **`compiler-gcc5.h: No such file`** — 2.6.x ships only `compiler-gcc{3,4}.h` but
  `compiler-gcc.h` does `#include compiler-gcc<__GNUC__>.h`. Shim: copy the gcc4 header to
  `compiler-gcc<major>.h` (pure dispatch, no codegen change).
- **`multiple definition of pin_inotify_watch`** — gcc 5 defaults to C99 (gnu11) inline; 2.6.x
  assumes gnu89, so plain-`inline` header funcs emit duplicate external defs. Fix:
  `-fgnu89-inline` (sed into the top Makefile's `-fno-common` line).
- **`timeconst.pl: defined(@array)`** — modern host Perl (≥5.22) removed that syntax; sed it out.

**`buildKernel` VALIDATED ACROSS ALL BANDS (2026-06-30):** `nix build -f validate-bands.nix all`
builds a stock kernel per modern era to a correct-arch `vmlinux`, exercising both sourcing paths:
- **k3-mipsel** 3.18.140 `malta_defconfig` — Bootlin k3 (gcc 6.4) → MIPS32 rel2 ELF
- **k3-x86_64** 3.18.140 `x86_64_defconfig` — **from-source** mcm gcc 6.5.0 → x86-64 ELF
- **k4-arm64** 5.10 `defconfig` — Bootlin k4 (gcc 9.3) → AArch64 PIE ELF
- **k6-x86_64** 6.6 `x86_64_defconfig` — Bootlin k6 (gcc 13.3) → x86-64 ELF

(plus k2.6 2.6.31/armel from `validate-k26.nix`.) Two general `buildKernel` fixes fell out:
`patchShebangs scripts tools` (5.10's `scripts/ld-version.sh` has a `#!/usr/bin/awk` shebang absent
in the sandbox) and adding **rsync** to `nativeBuildInputs` (kernels ≥5.3 shell out to it in
`headers_install`).

**FULL BAND×ARCH KERNEL SWEEP (2026-07-02):** `nix build -f validate-sweep.nix all` builds one
stock kernel per band across every kernel-capable arch (42 cells) to a `vmlinux`, using
endianness/width-definite defconfigs (SGI Indy/Origin, Loongson, PowerMac) so a pass certifies
the ABI. **Result: 32/42.**

| Band | Pass | Fails (root cause, not flag-noise) |
|---|---|---|
| k6 (6.6) | **11/11** | — |
| k4 (5.10) | 10/11 | x86_64: `objtool` under `tools/` has its own `-Werror` (gcc-13 use-after-free), unreachable by `HOSTCFLAGS` |
| k3 (3.18) | 9/11 | powerpc64: ELFv1/ELFv2 ABI (musl is elfv2, BE kernel is `-mcall-aixdesc`/elfv1); powerpc64le: vdso32 sub-build invokes host gcc |
| k2.6 (2.6.31) | 2/9 → **3/9** | see the TRUE gcc-4.x section below — moving k2.6 to gcc 4.9.4 removed the hard errors and recovered powerpc |

Two `kernel.nix` `eraQuirks` fixes landed (recovered the 3 k3 `dtc` cells, no regressions):
`KCFLAGS=-Wno-error` (cross warnings) and `HOSTCFLAGS` `-fcommon`/`-Wno-error` (host `dtc`/`objtool`).

**The sweep's headline finding:** the residual failures are **characterized root causes**, not noise,
and they cluster by era. Modern kernels (k4/k6) are essentially clean. The frontier is **k2.6**, which
the next section tackles.

## TRUE gcc-4.x for the k2.6 band (2026-07-02)

The k2.6 sweep above ran under gcc 5.3.0 and hit *hard* errors that no flag can fix (mips
`arch/mips/mm/page.c` aliases a function to a variable — rejected outright by gcc ≥5; x86 vDSO
`-m elf_x86_64`). Those are gcc-being-too-new symptoms, so we built a genuinely era-appropriate
**gcc 4.9.4** cross toolchain from source (musl-cross-make). The feared "modern host can't compile
2010s gcc" wall did **not** materialize; it was five small, individually-gated (`gccVer < 5`) fixes
in `mk-cross-toolchain.nix`:

1. refresh the pre-musl `config.sub`/`config.guess` from nixpkgs `gnu-config` (old ones reject
   `*-linux-musl*` triples);
2. use gcc **4.9.4** (4.7.4's in-tree `mpc` can't detect a modern `mpfr`);
3. synthesize the mcm `hashes/` entry from the staged tarball (4.9.4 isn't in mcm's blessed set);
4. `touch` staged tarballs newer than those hashes, else make fires an offline `wget`;
5. build gcc's own C++03-era source with `-std=gnu++03` (host gcc 13 defaults to C++17), and build
   the k2.6 band `languages = "c"` (its libstdc++ predates musl's `_IS*` ctype macros).

**Result: k2.6 → 3/9** (armel, armhf, **powerpc**), verified: gcc 4.9.4 produces correct ARM ELF
(static + dynamic musl). A `kernel.nix` k2.6 quirk (strip standalone `-Werror` from the old tree's
Makefiles — it lands after `KCFLAGS` and wins on precedence) recovered powerpc.

**Honest status — the k2.6 non-ARM tail is layered, not single-cause.** gcc 4.9.4 removed the hard
errors, but each remaining arch peels back to the *next* modern-tooling-vs-2009-kernel issue:
- **mips ×4**: the *toolchain* itself fails — gcc 4.9's MIPS `libgcc` unwinder needs `asm/unistd.h`
  in the build sysroot (which mcm populates too late). Blocks before the kernel. (This also means
  `.#k26-all` no longer builds all 12 toolchains — the 6 mips/mips64 cells regressed until this is
  fixed; the 6 non-mips k2.6 toolchains build.)
- **powerpc64**: past `-Werror`, now `arch/powerpc/Makefile:171` (`bootwrapper_install %.dtb:`) trips
  modern GNU make ≥4.3's "mixed implicit and normal rules" (plus the ELFv1/v2 ABI underneath).
- **x86_64**: past the vDSO issue, now a `percpu_to_op` inline-asm macro error under gcc 4.9.

So gcc 4.9.4 is **necessary but not sufficient** for full k2.6 coverage. ARM (the primary firmware
target) is solid; completing mips/ppc64/x86 is a per-arch effort, prioritize by firmware need.
Concrete next fixes: (a) install kernel headers into the build sysroot before `libgcc` (unblocks all
4 mips — likely the highest leverage); (b) patch the modern-make mixed-rules line for ppc; (c) the
x86 percpu macro. Fallback if from-source stays painful for an arch: **kernel.org crosstool** ships
prebuilt gcc 4.9 (kernel-build-only, glibc).

Next: (a) **true gcc-4.x for k2.6** (the mcm stable-pin work) — the highest-leverage fix, would likely
clear most of the k2.6 column at once; (b) a **`-Wno-error` compiler wrapper** (appends the flag *last*,
defeating `-Werror` wherever it is injected — kernel, subdir, or `tools/` — a cleaner general lever than
the three separate make-var knobs); (c) ppc64-BE `-mabi=elfv1` forcing + vDSO cross-propagation fix;
(d) build against a *real* firmware kernel config (needs the rehosting `linux` branch + `linux_builder`);
(e) a `buildModule` entrypoint to compile out-of-tree modules (e.g. igloo_driver) against a *prebuilt*
`kernel-devel` — i.e. build modules for kernels whose source you don't have; (f) mirror host + `base`.

## Tarball mirror (reproducibility)

Every pinned tarball (mcm components in `sources.nix`, Bootlin SDKs in `bootlin-sources.nix`)
is fetched **mirror-first, upstream-fallback** via `mirror.nix`: `fetchurl { urls = [ <mirror>
<upstream> ]; }`. The sha256 guarantees identical bytes whichever wins, so the mirror needs no
separate trust. Upstream pins are not "reproducible forever" (GNU prunes old point releases,
Bootlin rotates its download area) — the mirror is the durable copy.

**Currently inert:** `base = null` in `mirror.nix`, so fetches are upstream-only (verified: a
toolchain's store hash is unchanged by the refactor). To turn the mirror on:
1. `MIRROR_DEST=<target> ./mirror-upload.sh` — builds `.#mirror-tarballs` (all 42 tarballs,
   named by upstream basename) and uploads them. Supports `s3://…`, `user@host:/path`, local dirs.
2. Set `base` in `mirror.nix` to the HTTP(S) URL serving that directory.

The mirror must serve plain HTTP(S) GETs by basename (S3/MinIO, nginx, release assets) — Harbor's
OCI registry can't serve plain tarballs, so use an object store / file host, not the registry API.

## Toolchain-sourcing decision (from research, 2026-06-28)

Verified gcc floors the resolver clamps to: mainline **8.1** (binutils 2.30); **≥5.1**
from Linux 5.15; **4.9** global + **5.1 for arm64** pre-5.15; old kernels practically
**≥4.1** (4.3 on several arches; the documented 3.2 is folklore).

**Sourcing strategy: vendor-and-pin prebuilt toolchains, do NOT build ancient gcc from
source.** Building old gcc under modern nixpkgs is fragile (gcc 3.x vs modern glibc).
- **Primary:** Bootlin prebuilt **musl** toolchains (open Buildroot recipes), `fetchurl`
  + sha256, **mirrored to our own store** — upstream pinning is not "reproducible forever".
- **Fallback:** `musl-cross-make`-in-Nix (the current `mk-cross-toolchain.nix`) only for
  bands Bootlin doesn't cover old enough.
- kernel.org/crosstool is **kernel-build-only** (can't build guest userland) → not the sole source.

**Caveat — upper bounds are unverified:** the cases where a *new* gcc breaks an *old*
kernel (asm-goto, PIE defaults, `-Werror`) are folklore, not cited. Validate each cell's
upper bound empirically; treat the band table as data to correct, not as ground truth.

**Bootlin coverage (resolved 2026-06-29):** Bootlin archives every release back to
**2017.05**, all libc flavors incl. **musl**, for our arches. **Oldest gcc = 5.4.0; no
gcc 4.x.** Modern end reaches gcc 15.1 (2025.08). So:

| Band | Source |
|------|--------|
| k6 / k4 / k3 (gcc ≥5.4) | **vendor Bootlin musl prebuilt** (covers the majority of cells) |
| **k2.6** (needs gcc 4.x) | **musl-cross-make fallback** — Bootlin has nothing below 5.4 |

2.6 is a real target (2.6.31 ARM firmware in the wild), so the fallback band is needed, not hypothetical.

**Per-arch Bootlin coverage (k6 band, found while pinning):** 9 of 12 arches map cleanly to
a modern Bootlin musl SDK (armel, armhf, arm64, mipseb, mipsel, powerpc, powerpc64,
powerpc64le, x86_64). Three need musl-cross-make even for modern bands:
- `powerpcle` — Bootlin has no 32-bit powerpc little-endian variant at all.
- `mips64el` — Bootlin only ships it as n32 ABI (`mips64el-n32`), not the n64 our target wants.
- `mips64eb` — the `mips64` dir has musl only at 2017.05 (gcc 5.4); newer releases dropped musl.

So musl-cross-make owns: **all of k2.6 (12 arches) + the modern bands of those 3 arches.**

## Next steps

1. ~~Verify Bootlin's gcc-version coverage for the old (2.6/3.x) bands.~~ ✅ done above.
2. Pivot `sources.nix` → Bootlin `fetchurl` entries (mirror to Harbor) for k3/k4/k6;
   `mk-cross-toolchain.nix` → unpack + `patchelf` derivation. Keep the musl-cross-make
   path for k2.6 only.
3. Prove one cell end-to-end (the `spike`), then widen the matrix.
