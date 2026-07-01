#!/usr/bin/env bash
# Populate the tarball mirror that mirror.nix fetches from.
#
# Builds the `mirror-tarballs` linkFarm (every pinned mcm component + Bootlin
# SDK, named by upstream basename) and uploads the files to MIRROR_DEST under
# those exact basenames — the flat layout mirror.nix expects at `base`.
#
# IMPORTANT: the mirror must serve plain HTTP(S) GETs by basename (S3/MinIO,
# nginx, GitHub release assets, …). Harbor's OCI registry does NOT serve plain
# tarballs, so point this at an object store / file host, not the registry API.
#
# Usage:
#   MIRROR_DEST=s3://my-bucket/kernelsmith-sources ./mirror-upload.sh
#   MIRROR_DEST=user@host:/srv/mirror/kernelsmith  ./mirror-upload.sh
#   MIRROR_DEST=/mnt/mirror/kernelsmith            ./mirror-upload.sh
#
# After uploading, set `base` in mirror.nix to the HTTP(S) URL that serves this
# directory, e.g. base = "https://minio.example/kernelsmith-sources";
set -euo pipefail

dest="${MIRROR_DEST:-}"
if [ -z "$dest" ]; then
  echo "usage: MIRROR_DEST=<target> $0" >&2
  echo "  target: s3://bucket/prefix | user@host:/path | /local/or/mounted/path" >&2
  exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"
echo "building mirror-tarballs …" >&2
out="$(nix build --no-link --print-out-paths "$here#mirror-tarballs")"

# Stage real files (dereference the linkFarm symlinks) under their basenames.
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -Lf "$out"/* "$stage"/
echo "staged $(find "$stage" -type f | wc -l) tarballs from $out" >&2

case "$dest" in
  s3://*)  aws s3 cp --recursive "$stage/" "$dest/" ;;
  *:*)     rsync -av -e ssh "$stage/" "$dest/" ;;   # user@host:/path
  *)       mkdir -p "$dest"; cp -f "$stage"/* "$dest"/ ;;  # local / mounted
esac

echo "done -> $dest" >&2
echo "now set base in mirror.nix to the HTTP(S) URL serving that directory." >&2
