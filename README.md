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

## Status: vendored path proven; matrix not yet filled

- `nix build .#bootlin-spike` **works**: fetches the pinned Bootlin mips32 musl SDK,
  relocates + autoPatchelfs it, and the result compiles a real ELF MIPS32 binary
  (gcc 13.3.0). This validates the **primary (vendored Bootlin) sourcing path**.
- The flake evaluates the full 48-cell musl-cross-make matrix, `resolve` + `toolchainFor`
  verified — but those cells' `sources.nix` hashes are `fakeSha256` placeholders (the
  k2.6/from-source fallback path is not built yet).
- Next: pin the remaining Bootlin tarballs (one per arch × k3/k4/k6) and route the
  matrix through `mkBootlinToolchain`, leaving only k2.6 on musl-cross-make.

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
