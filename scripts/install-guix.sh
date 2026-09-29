#!/usr/bin/env bash
# Bootstrap Guix on an ephemeral CI runner without requiring an init system.
set -euo pipefail

: "${RUNNER_TEMP:?This script requires a GitHub Actions runner.}"
: "${GITHUB_ENV:?This script requires a GitHub Actions runner.}"
: "${GITHUB_PATH:?This script requires a GitHub Actions runner.}"

if [[ $(uname -m) != x86_64 ]]; then
  echo "The installer build requires an x86_64 runner." >&2
  exit 1
fi

guix_profile=/var/guix/profiles/per-user/root/current-guix
substitute_urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://nonguix-proxy.ditigal.xyz'
daemon_log="$RUNNER_TEMP/guix-daemon.log"
daemon_pid_file="$RUNNER_TEMP/guix-daemon.pid"
work_dir=$(mktemp -d "$RUNNER_TEMP/guix-install.XXXXXXXX")

cleanup() {
  local status=$?
  if (( status != 0 )) && [[ -f "$daemon_log" ]]; then
    echo 'Guix daemon log:' >&2
    sudo tail -n 100 "$daemon_log" >&2
  fi
  rm -rf -- "$work_dir"
  exit "$status"
}
trap cleanup EXIT

if [[ -x "$guix_profile/bin/guix" && -x "$guix_profile/bin/guix-daemon" && -s /var/guix/db/db.sqlite ]]; then
  echo 'Reusing cached Guix installation.'
else
  if [[ -d /gnu/store || -d /var/guix/db ]]; then
    echo 'Incomplete Guix installation in cache; reset the Namespace cache volume before retrying.' >&2
    exit 1
  fi
  curl --fail --location --silent --show-error --retry 3 \
    'https://ci.guix.gnu.org/search/latest/archive?query=spec:tarball+status:success+system:x86_64-linux+guix-binary.tar.xz' \
    --output "$work_dir/guix-binary.tar.xz"
  sudo tar --extract --file "$work_dir/guix-binary.tar.xz" --directory / --no-overwrite-dir
fi

# Keep builds under separate users, with the daemon retaining sandbox support.
if ! getent group guixbuild >/dev/null; then
  sudo groupadd --system guixbuild
fi
for number in {01..10}; do
  if ! id "guixbuilder$number" >/dev/null 2>&1; then
    sudo useradd --system --gid guixbuild --groups guixbuild \
      --home-dir /var/empty --shell "$(command -v nologin)" "guixbuilder$number"
  fi
done
sudo install -d -m 755 -o "$(id -u)" -g "$(id -g)" \
  "/var/guix/profiles/per-user/$(id -un)"

for key in "$guix_profile"/share/guix/*.pub; do
  # These public keys are readable by the runner; only the ACL update needs root.
  # shellcheck disable=SC2024
  sudo "$guix_profile/bin/guix" archive --authorize < "$key"
done
sudo "$guix_profile/bin/guix" archive --authorize <<'PUBKEY'
(public-key (ecc (curve Ed25519) (q #C1FD53E5D4CE971933EC50C9F307AE2171A2D3B52C804642A7A35F84F3A4EA98#)))
PUBKEY
sudo "$guix_profile/bin/guix" archive --generate-key

# Namespace runs the job in a container without systemd. Detach the daemon from
# this step's stdio so it can serve subsequent steps; the final job step stops it.
sudo env LC_ALL=C SSL_CERT_DIR=/etc/ssl/certs sh -c '
  nohup "$1" --build-users-group=guixbuild --substitute-urls="$2" \
    > "$3" 2>&1 < /dev/null &
  echo "$!" > "$4"
' sh "$guix_profile/bin/guix-daemon" "$substitute_urls" "$daemon_log" "$daemon_pid_file"

daemon_pid=$(cat "$daemon_pid_file")
daemon_ready=false
for _ in {1..30}; do
  if ! sudo kill -0 "$daemon_pid" 2>/dev/null; then
    echo 'Guix daemon exited during startup.' >&2
    exit 1
  fi
  if timeout 5 "$guix_profile/bin/guix" gc --list-roots >/dev/null 2>&1; then
    daemon_ready=true
    break
  fi
  sleep 1
done
if [[ "$daemon_ready" != true ]]; then
  echo 'Timed out waiting for the Guix daemon.' >&2
  exit 1
fi

printf '%s\n' "$guix_profile/bin" >> "$GITHUB_PATH"
printf '%s\n' 'LANG=en_US.utf8' 'SSL_CERT_DIR=/etc/ssl/certs' >> "$GITHUB_ENV"
# The build's existing guix time-machine resolves guix/base-channels.scm, so an
# additional root guix pull (and daemon restart) is unnecessary here.
"$guix_profile/bin/guix" --version
echo 'Guix daemon is ready.'
