#!/usr/bin/env bash
set -euo pipefail

limit=${GUIX_CACHE_MAX_BYTES:-40000000000}
if [[ ! "$limit" =~ ^[1-9][0-9]*$ ]]; then
  echo 'GUIX_CACHE_MAX_BYTES must be a positive integer.' >&2
  exit 1
fi

cache_size() {
  sudo du -scB1 /gnu /var/guix "${XDG_CACHE_HOME:-$HOME/.cache}/guix" |
    awk '$2 == "total" { print $1 }'
}

size=$(cache_size)
echo "Guix cache uses $size bytes; target is $limit bytes."
if (( size > limit )); then
  guix gc --collect-garbage="$((size - limit))"
  size=$(cache_size)
  echo "Guix cache uses $size bytes after garbage collection."
  if (( size > limit )); then
    echo '::warning::Live Guix data exceeds the cache budget; increase the Namespace volume size and GUIX_CACHE_MAX_BYTES.'
  fi
fi
