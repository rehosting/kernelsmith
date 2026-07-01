# Central mirror policy for every pinned tarball (toolchain components + Bootlin
# SDKs). Upstream pins are NOT "reproducible forever" — GNU prunes old point
# releases, Bootlin rotates its download area — so we mirror the exact bytes and
# fetch mirror-first, upstream-fallback. The sha256 on each fetchurl guarantees
# identical content whichever source wins, so the mirror needs no separate trust.
#
# HOW TO TURN ON THE MIRROR: set `base` to the mirror's HTTP base URL (the
# directory that `mirror-upload.sh` populates). Until then `base = null` and
# every fetch is upstream-only — nothing breaks, we just have no fallback yet.
#
# Object naming is flat: each tarball lives at `${base}/${baseNameOf upstream}`.
# All our upstream basenames are unique (gcc-6.5.0.tar.xz,
# armv5-eabi--musl--stable-2024.05-1.tar.xz, linux-2.6.31.tar.xz, …), so a flat
# namespace is collision-free and `mirror-upload.sh` can derive names the same way.
{ lib }:
rec {
  # e.g. "https://harbor.example/kernelsmith-sources" or an S3/MinIO/HTTP root.
  base = null;

  # upstreamUrl -> ordered url list for fetchurl { urls = ...; }
  # mirror first (when configured), upstream last as the always-present fallback.
  mirrored = url:
    lib.optional (base != null) "${base}/${baseNameOf url}" ++ [ url ];
}
