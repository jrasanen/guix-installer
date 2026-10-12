#!/usr/bin/env bash
set -euo pipefail

pid_file="$RUNNER_TEMP/guix-daemon.pid"
if [[ ! -f "$pid_file" ]]; then
  exit 0
fi

pid=$(cat "$pid_file")
if ! sudo kill -0 "$pid" 2>/dev/null; then
  exit 0
fi
sudo kill "$pid"
for _ in {1..30}; do
  state=$(ps -o stat= -p "$pid" || true)
  if [[ -z "$state" || "$state" == Z* ]]; then
    exit 0
  fi
  sleep 1
done
echo 'Guix daemon did not stop within 30 seconds.' >&2
exit 1
