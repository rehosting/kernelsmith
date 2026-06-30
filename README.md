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
validate-k26.nix` builds a stock **kernel.org 2.6.31** (RV130's generation) ARM `vmlinux`
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

Next: (a) build against RV130's *actual* 2.6.31 config (needs the rehosting `linux` branch +
`linux_builder`, not checked out in this workspace) to confirm firmware-config coverage;
(b) ~~fill the remaining from-source cells~~ ✅ done (`.#k26-all` + `.#fromsource-extra`);
(c) mirror the Bootlin tarballs + the GNU/musl/kernel.org component tarballs to Harbor
(upstream pins are not "reproducible forever"); (d) exercise `buildKernel` on a k3/k4/k6 kernel.

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

2.6 is a real target (RV130 = 2.6.31 ARM), so the fallback band is needed, not hypothetical.

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
