#!/usr/bin/env bash
# Publish files using explicit FTPS.
set -euo pipefail

fail() {
  echo "$*" >&2
  exit 1
}

case "${1:-}" in
  preflight) [[ $# == 1 ]] || fail "Usage: $0 preflight" ;;
  upload)
    [[ $# == 3 ]] || fail "Usage: $0 upload LOCAL_FILE REMOTE_NAME"
    [[ -f "$2" && -r "$2" ]] || fail "Upload source must be a readable file."
    [[ "$3" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]] || fail "Remote name must be a simple filename."
    ;;
  *) fail "Usage: $0 preflight | upload LOCAL_FILE REMOTE_NAME" ;;
esac

for setting in FTP_UPLOAD_URL DOWNLOAD_BASE_URL FTP_USERNAME FTP_PASSWORD; do
  [[ -n "${!setting:-}" ]] || fail "Missing required setting: $setting"
done
[[ "$FTP_UPLOAD_URL" == ftp://?* ]] || fail "FTP_UPLOAD_URL must use ftp:// for explicit FTPS."
[[ "$DOWNLOAD_BASE_URL" == https://?* ]] || fail "DOWNLOAD_BASE_URL must use https://."

run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
[[ "$run_id" =~ ^[[:alnum:]_-]+$ ]] || fail "Invalid workflow run identifier."
upload_url="${FTP_UPLOAD_URL%/}/"
download_url="${DOWNLOAD_BASE_URL%/}"

# Disable curlrc loading and keep all credentials out of URLs and diagnostic output.
# Certificate verification is intentionally disabled for FTPS, including self-signed
# certificates. TLS is still required for both the control and data connections.
ftp_curl=(curl --disable --silent --show-error --globoff --proto '=ftp'
  --ssl-reqd --insecure --ftp-pasv --ftp-method singlecwd
  --connect-timeout 30 --speed-limit 1 --speed-time 120
  --user "${FTP_USERNAME}:${FTP_PASSWORD}")

retry() {
  local attempt=0
  until "$@"; do
    attempt=$((attempt + 1))
    if (( attempt >= 5 )); then
      echo "Transfer failed after five attempts." >&2
      return 1
    fi
    echo "Transfer failed; retrying (attempt $((attempt + 1))/5)." >&2
    sleep $((attempt * attempt))
  done
}

delete_remote() {
  # '+' runs DELE after curl has entered the configured upload directory.
  # HEAD avoids downloading a directory listing; cleanup has a bounded duration.
  "${ftp_curl[@]}" --connect-timeout 10 --max-time 20 --head \
    --quote "+DELE $1" --output /dev/null "$upload_url"
}

work_dir=$(mktemp -d)
remote_temp=''
probe_file=''
cleanup() {
  local status=$?
  trap - EXIT
  for name in "$remote_temp" "$probe_file"; do
    if [[ -n "$name" ]]; then
      if ! delete_remote "$name"; then
        echo "Could not remove temporary remote file: $name" >&2
      fi
    fi
  done
  rm -rf -- "$work_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_id="$run_id-${work_dir##*.}"

upload() {
  local source=$1 destination=$2
  remote_temp=".${destination}.${run_id}.part"
  echo "Uploading $destination"
  # Post-transfer RNFR/RNTO runs only after STOR succeeds. Never delete the old
  # destination first. Retrying uploads the same bytes again, even if the server
  # completed a rename but the acknowledgement was lost.
  retry "${ftp_curl[@]}" --upload-file "$source" \
    --quote "-RNFR $remote_temp" --quote "-RNTO $destination" \
    "${upload_url}${remote_temp}"
  remote_temp=''
}

verify_download() {
  # FTPS's --insecure is deliberately absent from this separate HTTPS client.
  retry curl --disable --silent --show-error --globoff --fail --location \
    --proto '=https' --proto-redir '=https' --connect-timeout 30 --max-time 120 \
    --header 'Cache-Control: no-cache' --output "$work_dir/download" \
    "${download_url}/${probe_file}?check=$1"
  cmp -- "$work_dir/probe" "$work_dir/download" || fail "HTTPS download does not match the uploaded probe."
}

if [[ "$1" == preflight ]]; then
  probe_file="_preflight-${run_id}.bin"
  # Different contents exercise replacement, not just a successful first upload.
  dd if=/dev/urandom of="$work_dir/probe" bs=1M count=1 status=none
  upload "$work_dir/probe" "$probe_file"
  verify_download initial
  dd if=/dev/urandom of="$work_dir/probe" bs=1M count=1 status=none
  upload "$work_dir/probe" "$probe_file"
  verify_download replacement
  retry delete_remote "$probe_file"
  probe_file=''
  echo "FTPS upload, rename, replacement, HTTPS download, and deletion verified."
else
  upload "$2" "$3"
fi
