#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_OUTPUT:?This script requires a GitHub Actions runner.}"
: "${DOWNLOAD_BASE_URL:?Missing DOWNLOAD_BASE_URL.}"
release_tag=$(cat dist/release-tag)
if [[ ! "$release_tag" =~ ^[0-9]{12}$ ]]; then
  echo 'Invalid release tag in installer artifact.' >&2
  exit 1
fi
file="guix-installer-$release_tag.iso"
latest_file=guix-installer-latest.iso
(
  cd dist
  sha256sum --check SHA256SUMS
)
iso_bytes=$(stat --printf='%s' "dist/$file")
iso_size=$(numfmt --to=iec-i --suffix=B "$iso_bytes")
download_url="${DOWNLOAD_BASE_URL%/}/$file"
latest_url="${DOWNLOAD_BASE_URL%/}/$latest_file"

{
  printf 'Download the ISO below and write it directly to a USB drive.\n\n'
  printf '**Direct Download:** [%s](%s)\n\n' "$download_url" "$download_url"
  printf '**Latest Version:** [%s](%s)\n\n' "$latest_url" "$latest_url"
  printf '**Size:** %s (%s bytes)\n\n' "$iso_size" "$iso_bytes"
  printf '**SHA256 Checksums:**\n```\n'
  cat dist/SHA256SUMS
  printf '%s\n' '```' '' 'Installer image prepared with the following channel configuration:' '' '```scheme'
  cat dist/channels.scm
  printf '```\n'
} > dist/release-notes.md

bash scripts/ftp-upload.sh upload "dist/$file" "$file"
bash scripts/ftp-upload.sh upload "dist/$file" "$latest_file"

printf 'release_tag=%s\n' "$release_tag" >> "$GITHUB_OUTPUT"
if (( iso_bytes < 2147483648 )); then
  printf 'iso_asset=dist/%s\n' "$file" >> "$GITHUB_OUTPUT"
else
  printf 'iso_asset=\n' >> "$GITHUB_OUTPUT"
  echo 'ISO exceeds the GitHub release asset limit; the release will link to the FTP-hosted download.'
fi
