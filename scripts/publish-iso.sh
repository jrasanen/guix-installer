#!/usr/bin/env bash
set -euo pipefail

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

cat > dist/release-notes.md <<EOF
[Download ISO]($download_url) ($iso_size, $iso_bytes bytes) · [Latest ISO]($latest_url)

Write the ISO directly to a USB drive.

SHA256 checksums:

\`\`\`
$(cat dist/SHA256SUMS)
\`\`\`

Channels:

\`\`\`scheme
$(cat dist/channels.scm)
\`\`\`
EOF

python3 scripts/ftp-upload.py upload "dist/$file" "$file"
python3 scripts/ftp-upload.py upload "dist/$file" "$latest_file"

printf 'release_tag=%s\n' "$release_tag" >> "$GITHUB_OUTPUT"
if (( iso_bytes < 2147483648 )); then
  printf 'iso_asset=dist/%s\n' "$file" >> "$GITHUB_OUTPUT"
else
  printf 'iso_asset=\n' >> "$GITHUB_OUTPUT"
  echo 'ISO exceeds the GitHub release asset limit; the release will link to the FTP-hosted download.'
fi
