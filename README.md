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
| `mk-cross-toolchain.nix` | builds one (arch, versions) **musl** toolchain (userland; and the k3+ kernel bands) |
| `mk-kernel-toolchain.nix` | builds one **kernel-only, no-libc** period toolchain (the k2.6 kernel band — see the reframe below) |
| `sources.nix` | pinned component / toolchain inputs |
| `kernel.nix` | `buildKernel { version, arch, src, config }` — auto-resolves the toolchain (kernel toolchain for k2.6, else musl); emits `vmlinux` + the arch's bootable image (ARM `zImage`, x86 `bzImage`, arm64 `Image.gz`) + `kernel-devel` |

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

The k2.6 sweep above ran under gcc 5.3.0 and hit errors that pointed to the compiler being too new
for a 2009 tree (x86 vDSO `-m elf_x86_64`; gcc-5 C++/inline behavior), so we built a genuinely
era-appropriate **gcc 4.9.4** cross toolchain from source (musl-cross-make). The feared "modern host
can't compile 2010s gcc" wall did **not** materialize; it was five small, individually-gated
(`gccVer < 5`) fixes in `mk-cross-toolchain.nix`:

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

A separate `mk-cross-toolchain.nix` fix repairs the **MIPS toolchain**: gcc 4.9's MIPS `libgcc`
unwinder `#include <asm/unistd.h>`, which mcm otherwise stages into the build sysroot too late
(after `libgcc`). Adding a `libgcc → kernel-headers-in-obj_sysroot` dependency (gated to `gccVer<5`)
fixes it, so **`.#k26-all` builds all 12 k2.6 toolchains** — important for MIPS *module* and
other-version kernel builds even though it doesn't fix the 2.6.31 kernel (below).

**Honest status — the k2.6 non-ARM tail is layered, and mostly NOT a toolchain problem.** gcc 4.9.4
removed the *host/build* hard errors (vDSO, C++17 source, libstdc++, config.sub) and all 12
toolchains build, but the remaining kernel failures are **kernel-source/arch issues that persist
under gcc 4.9.4**:
- **mips ×4**: `arch/mips/mm/page.c` aliases a *function* to a *variable* — rejected by gcc 4.9 too
  (**not** a gcc-5-only error, as first assumed), plus `r4k_switch.S` uses FPU opcodes
  (`mtc1 $f30/$f31`) the assembler rejects for the configured ISA. Both need kernel source patches.
- **powerpc64**: `arch/powerpc/Makefile:171` (`bootwrapper_install %.dtb:`) trips modern GNU make
  ≥4.3's "mixed implicit and normal rules" (plus the ELFv1/v2 ABI underneath).
- **x86_64**: a `percpu_to_op` inline-asm macro error under gcc 4.9.

So gcc 4.9.4 is **necessary but not sufficient**: it (plus the MIPS toolchain fix) gets the whole
k2.6 *toolchain* row green, and gets ARM + powerpc *kernels* building, but the mips/ppc64/x86 2.6.31
*kernels* need per-arch **source** patches, not toolchain work. ARM (the primary firmware target) is
solid. Prioritize the rest by firmware need. Fallback if a given arch's from-source path stays
painful: **kernel.org crosstool** ships prebuilt gcc 4.9 (kernel-build-only, glibc).

### Testing a *truly* period-correct gcc 4.4.7 — the musl wall, then the kernel-only reframe (2026-07-03)

The open question was whether an even more era-matched **gcc 4.4.7** (what 2.6.31 was literally built
with) would clear the residual kernel-source failures (`page.c` alias, etc.) with *fewer* shims than
4.9.4. Tested directly (mipsel, from source, binutils held at 2.27 to isolate the gcc variable). Two
things came out of it, one expected and one decisive:

- **The compiler proper builds fine** — the "ancient gcc won't build under a 2026 host" fear is again
  false. It needed only one new shim beyond 4.9.4's: build gcc's own C with `CC="gcc -std=gnu89
  -fgnu89-inline"` (gcc <4.8 is written in gnu89 C; host gcc's gnu11 inline made `floor_log2`/
  `exact_log2` in `toplev.c` redefinitions). `all-gcc` completed clean.
- **But it can't consume our pinned musl 1.1.24.** First its MIPS `libgcc` unwinder failed
  (`config/mips/linux-unwind.h`: `struct siginfo` — a named tag glibc has but musl doesn't; fixable
  with the same one-line `struct siginfo`→`siginfo_t` patch mcm ships for *blessed* versions). Clearing
  that only exposed the real wall: **musl 1.1.24's own headers don't parse under gcc 4.4.7** —
  `bits/alltypes.h` fails with `duplicate 'unsigned'` / `two or more data types`. Same sysroot gcc
  4.9.4 parsed cleanly; only the compiler version changed.

**Conclusion (scoped to a *musl* toolchain):** musl-cross-make blesses a specific set of gcc versions
precisely because each needs a maintained (gcc × musl) compatibility patch set. **gcc 4.9.4 is the
*oldest* gcc that cleanly consumes modern musl 1.1.24** — going below it doesn't reduce shims, it
*leaves the supported envelope* and trades a few kernel-source patches for an open-ended musl-header
porting burden. For a *musl* toolchain, 4.9.4 **is** the practical period floor.

### The reframe that unblocks it: kernels don't need a target libc (2026-07-03, decisive)

The wall above was a **musl anachronism, not a gcc-age wall** — musl 1.1.24 (2019) is a decade newer than
2.6.31 (2009), and the **kernel is built `-nostdinc -ffreestanding`: it needs no target libc at all**
(libgcc ships *inside* gcc). musl only matters for *userland* (busybox, guest utils). So the k2.6
toolchain splits by purpose:

- **Kernel band:** build period gcc `--without-headers --with-newlib` (**no musl**). Tested for mipsel:
  gcc 4.4.7 builds clean on a 2026 host (one incidental snag — modern texinfo can't render gcc 4.4 docs,
  so `MAKEINFO=true`), and then compiles stock **2.6.31 `malta_defconfig` to a 5 MB `vmlinux` with
  *zero* k2.6 source shims** — no tree-wide `-Werror` strip, no `-fgnu89-inline`, no `KCFLAGS=-Wno-error`.
  The era-correct compiler doesn't need placating; those shims only ever existed to appease a compiler
  *newer* than the tree.
- **Userland band:** keep gcc 4.9.4 + musl 1.1.24 (the floor established above). Userland needn't be
  period-correct — it just has to run on the emulated kernel.

**This turns a red cell green, not merely prettier.** In-session control on the *same* tree/defconfig:
gcc 4.9.4 (current k2.6 toolchain, *with* all shims) **fails** — `arch/mips/mm/page.c:108: error:
'copy_page' alias in between function and variable is not supported` (a hard *error*, so `-Wno-error`
can't touch it) — while period gcc 4.4.7 (no shims) **succeeds**. Corrects a doc bug: `matrix.nix` blamed
gcc ≥5 for the `page.c` alias, but 4.9.4 (<5) rejects it too; the idiom's ceiling is ≤4.4. So the recurring
"true gcc-4.x for k2.6" NEXT item is **confirmed, not rejected** — scoped to a kernel-only (no-libc)
toolchain, now **landed** as `mk-kernel-toolchain.nix` (period gcc 4.4.7) + the `matrix.k26Kernel` band;
`buildKernel` auto-uses it for 2.6.x kernels while `toolchainFor` keeps the musl userland toolchain.
Build them all with `nix build .#k26-kernel-all`.

**Band sweep — all k2.6 arches, period gcc 4.4.7 (kernel-only), `bare` = every k2.6 source shim
stripped, `shims` = the existing `-Wno-error`/frame-size net kept:**

| arch | toolchain | bare | +shims | verdict |
|------|:--:|:--:|:--:|------|
| armel | ✅ | ✅ 3.9 MB | ✅ | green either way |
| armhf | ✅ | ✅ 7.0 MB | ✅ | green either way |
| mipsel | ✅ | ✅ 5.0 MB | ✅ | **was RED on 4.9.4** (`page.c` hard error) → period gcc fixes it |
| mipseb | ✅ | ✅ 4.0 MB | ✅ | bare, no shims |
| mips64eb | ✅ | ✅ 6.0 MB | ✅ | added in the completeness pass (`ip27`) |
| mips64el | ✅ | ✅ 5.8 MB | ✅ | added in the completeness pass (`fuloong2e`) |
| powerpc (32) | ✅ | ❌ | ✅ 7.6 MB | frame-size warning→error (gcc 4.4 bigger frames, a *too-old* artifact); `-Wno-error` net demotes it |
| powerpc64 | ✅ | ❌ | ✅ 13.3 MB | `pseries_defconfig` + `FTRACE` off (`kernel.nix` `kernelConfigDisable`): the function-graph tracer's return trampoline is the *only* `R_PPC64_ADDR16_HI` overflow (gcc 4.4 predates ppc64's medium code model); dropping that debug feature links clean |
| x86_64 | ✅ (native) | — | ✅ 17.6 MB | built as a genuine **native** gcc (target==host): a cross-with-newlib hits gcc's native-detection trap and an `-elf` triple omits the `__linux__`/OS predefines 2.6.31's x86 `.S` needs. Native gcc 4.4 + 3 sandbox fixes (fixincludes header dir, `struct ucontext`, `CPATH`) → clean |

Two corrections this surfaced: (1) ppc64 is **not** blocked by the make `"mixed implicit and normal
rules"` error — testing a period `make` (`gnumake42` = 4.2.1) proved those messages are *non-fatal* (the
fatal form is make ≥3.82; truly-period 3.81 is the hard-to-build-on-a-modern-host one), and the build
dies later at the linker regardless of make version; (2) the ppc64 reloc overflow is **not** iSeries-
specific (`pseries_defconfig` hits it too). Also, the `bare` column refined the thesis: the `-Wno-error`
net is **not** purely about appeasing a *too-new* gcc — ppc32's frame-size error is a *too-old* artifact —
so it's a general "this isn't the exact gcc the tree was tuned for" absorber, warranted for **any** gcc.

**Net:** band-wide period gcc 4.4.7 + the shim net is **green for all 9 kernel-capable arches** — arm×2,
mips×4 (32+64, both endians), ppc32, ppc64 (pseries + FTRACE off), and x86_64 (native gcc). The
non-negotiable win is **mips**, where period gcc removes a *hard error* (`page.c`) that no warning-demotion
can touch; the counterintuitive one is **x86_64** — "host==target" makes it the *awkward* case for a
cross-build system, and the fix was to stop fighting it as a cross and build a genuine native gcc.

### Completeness pass — #5/#6/#7 (2026-07-03)

- **#6 mips64eb/el [DONE]** — added to the kernel band; both build `vmlinux` via the real entrypoint
  (6.0/5.8 MB). MIPS is now complete (4 cells).
- **#7 `-Wno-error` compiler wrapper [DONE]** — `kernel.nix`'s `ccShim` wraps the cross gcc **and** the
  host cc so `-Wno-error` lands *last* on every compile, defeating `-Werror` wherever the tree injects it.
  This replaced three fragile knobs: `KCFLAGS=-Wno-error`, the tree-wide `-Werror` strip sed, and the
  `-Wno-error` inside `HOSTCFLAGS` (whose override-vs-append semantics flip at 4.19 — now irrelevant).
  Only the real host quirk `-fcommon` (k3 dtc) stays in `HOSTCFLAGS`. Revalidated: k2.6-mipsel/powerpc,
  k4-mipsel, k6-mipsel all green (k3-mipsel blocked only by a transient v3.x source-download failure).
- **#5 ppc64 [DONE], x86_64 [DONE]** — both landed. ppc64: the `R_PPC64_ADDR16_HI` link overflow came
  *only* from the function-graph tracer's return trampoline (gcc 4.4 predates ppc64's medium code model);
  `pseries_defconfig` + `FTRACE` off (`kernel.nix` `kernelConfigDisable`) → 13.3 MB `vmlinux`. Disproved
  two red herrings: *not* the make mixed-rules error (period `gnumake42` proved those non-fatal) nor
  iSeries-specific. x86_64: the `-elf` detour was the trap — it omits `__linux__`, so 2.6.31's x86 `.S`
  mis-preprocesses. Built a genuine **native** gcc 4.4 instead (`mk-kernel-toolchain.nix` `native` mode),
  clearing three sandbox walls a native ancient-gcc build assumes away — fixincludes' `/usr/include`
  (patch `NATIVE_SYSTEM_HEADER_DIR`), `struct ucontext` (glibc ≥2.26), and the in-build `xgcc`'s header
  search for target-libgcc's CPP check (`CPATH`). → 17.6 MB `vmlinux` via the real entrypoint.

**Boot-validated across eras, and automated — `nix build -f boot.nix all`.** The kernels don't just
compile, they boot, and that's a *build target*: `boot.nix` builds each (band, arch) system on a
qemu-friendly defconfig + fragments, then runs qemu headless in a sandboxed derivation and asserts the boot
reached the root-fs stage (no rootfs supplied → a `VFS: Unable to mount root fs` panic is the success
marker). A cell's derivation only succeeds if its kernel boots. Per band: `nix build -f boot.nix k4`;
one cell: `tests.k4-powerpc64`; interactive: `nix run -f boot.nix runners.k4-arm64`.

**k4 (5.10.229, gcc 9.x): all 11 arches boot** — armel/armhf/arm64, mipsel/mipseb/mips64el/mips64eb,
powerpc/powerpc64/powerpc64le, x86_64. The modern band clears every k2.6 gap: `powerpc64` and
`powerpc64le` boot on `-M pseries`, armhf and arm64 on the DT-driven `-M virt`. Fixes it surfaced:
5.10 must be a late `.y` (binutils 2.36 omits the symtab from empty objects like x86_64's `thunk_64.o`,
which 5.10.0's objtool rejects); `multi_v7` armhf needs `GCC_PLUGINS` off (plugin ABI ≠ the cross gcc);
ppc64le needs `COMPAT` off (its pure-64-bit LE toolchain can't build the 32-bit vdso); 64-bit malta needs
`-cpu MIPS64R2-generic` (the default malta CPU is 32-bit → silent); and modern DT-only versatile needs a
`-dtb` (buildKernel gained a `dtbs` param, installed to `$out/dtbs/`).

**k2.6 (2.6.31, period gcc 4.4.7): 8 of the 9 kernel-capable arches boot** (banner
`Linux version 2.6.31 (gcc version 4.4.7)`):

| cell | qemu | defconfig (+ fragments) | image |
|------|------|-------------------------|-------|
| `mipsel`   | `-M malta`          | `malta_defconfig`                                        | vmlinux |
| `mipseb`   | `-M malta` (BE)     | `malta_defconfig` +`CPU_BIG_ENDIAN` −`CPU_LITTLE_ENDIAN`  | vmlinux |
| `mips64el` | `-M fuloong2e`      | `fulong_defconfig`                                       | vmlinux |
| `mips64eb` | `-M malta` (mips64) | `malta_defconfig` →64-bit BE (+`64BIT`+`CPU_MIPS64_R1`+`CPU_BIG_ENDIAN`) | vmlinux |
| `armel`    | `-M versatilepb`    | `versatile_defconfig`                                    | zImage  |
| `armhf`    | `-M realview-pb-a8` | `realview_defconfig` →PBA8/ARMv7-only (needs the ARMv7 toolchain) | zImage |
| `powerpc`  | `-M g3beige`        | `pmac32_defconfig` +`SERIAL_PMACZILOG[_CONSOLE]`         | vmlinux |
| `x86_64`   | `-M pc`             | `x86_64_defconfig`                                       | bzImage |

`nix run -f boot.nix runners.k26-<arch>` boots any cell interactively. This is DISTINCT from
`validate-sweep.nix`, which picks endianness/width-*definite* boards (ip22/ip27/omap3430) that build but
have no qemu machine — those prove codegen, `boot.nix` proves boot; for the hard arches the win was
picking the period-correct model qemu *does* emulate (64-bit BE malta for `mips64eb`, a Cortex-A8
`realview-pb-a8` for `armhf`) instead of the endianness-definite board. Four subtleties surfaced by making
it *run*, not just eyeball it: (1) MIPS endianness/width are Kconfig `choice`s — enabling the wanted symbol
without disabling the default leaves the old `-EL`/32-bit image; (2) 2.6.31 PowerMac goes silent at
`turn off boot console udbg0` unless the escc console is built in (its `=m` default is a module, and
`keep_bootcon` postdates 2.6.31); (3) `armhf` needs its own `--with-arch=armv7-a` toolchain (else gas
rejects the ARMv7 `isb`/`dsb` in `cache-v7.S`) **and** a PBA8-only config (`realview_defconfig` is
multi-board; the v6 boards keep `CPU_V6` on and `arch/arm/Makefile` lets the v6 `-march` override v7).

**`powerpc64` is the one exception — a firmware wall, not a board or toolchain gap.** Exposed as a
build-only kernel (`kernels.k26-powerpc64`, the PowerMac G5 / 970 `g5_defconfig`): it compiles clean and
its `prom_init` runs, but no qemu ppc64 firmware boots a 2.6.31 ppc64 kernel — `-M mac99 -cpu 970`'s
OpenBIOS can't satisfy the kernel's device-tree `claim` (`No memory for flatten_device_tree`), and
`-M pseries`'s SLOF/PAPR platform postdates 2.6.31. Its codegen is cross-validated by `powerpc` (ppc32,
same gcc 4.4.7), which boots.

The sweep drove the **boot-image outputs** emitted by `kernel.nix`: ARM's ELF `vmlinux` entry is a
*virtual* address that qemu/bootloaders can't jump to before the MMU is on (MIPS boots vmlinux directly
via KSEG0), so each arch also ships the image it actually boots (`zImage`/`bzImage`/`Image.gz`).

Next: (a) extend the boot sweep to the modern bands (k3/k4/k6) — more arches boot there (arm64 `-M virt`,
`powerpc64`/`powerpc64le` on `-M pseries`, armhf on vexpress/virt), so those bands should clear the k2.6
gaps; (b) get `powerpc64` booting at 2.6.x — try a slightly later 2.6.3x kernel just for that cell (the
OpenBIOS OF-claim path improved shortly after 2.6.31); (c) build against a *real* firmware kernel config
(needs the rehosting `linux` branch + `linux_builder`); (d) a `buildModule` entrypoint to compile
out-of-tree modules (e.g. igloo_driver) against a *prebuilt* `kernel-devel`; (e) mirror host + `base`.

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
