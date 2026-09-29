#!/usr/bin/env bash
set -euo pipefail

install -Dm644 ./guix/base-channels.scm "${XDG_CONFIG_HOME:-$HOME/.config}/guix/trusted-channels.scm"
guix time-machine -C ./guix/base-channels.scm -- describe -f channels > ./guix/channels.scm

image_root="/var/guix/profiles/per-user/$(id -un)/ci-installer"
if [[ -L "$image_root" ]]; then
  unlink "$image_root"
fi
image=$(guix time-machine -C ./guix/channels.scm -- system image \
  --root="$image_root" -t iso9660 ./guix/installer.scm)
release_tag=$(date -u +'%Y%m%d%H%M')
file="guix-installer-$release_tag.iso"

mkdir -p dist
cp --reflink=auto -- "$image" "dist/$file"
cp -- ./guix/channels.scm dist/channels.scm
printf '%s\n' "$release_tag" > dist/release-tag
(
  cd dist
  sha256sum "$file" channels.scm > SHA256SUMS
)
ls -lh "dist/$file"
