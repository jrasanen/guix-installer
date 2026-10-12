#!/usr/bin/env python3
import filecmp
import os
import re
import signal
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    args = sys.argv[1:]
    preflight = args == ["preflight"]
    if preflight:
        if not os.environ.get("DOWNLOAD_BASE_URL", "").startswith("https://"):
            raise ValueError("DOWNLOAD_BASE_URL must use https://.")
    elif len(args) == 3 and args[0] == "upload":
        source = Path(args[1])
        name = args[2]
        if not source.is_file() or not os.access(source, os.R_OK):
            raise ValueError("Upload source must be a readable file.")
        if not re.fullmatch(r"[^\W_][\w.-]*", name):
            raise ValueError("Remote name must be a simple filename.")
    else:
        raise ValueError(f"Usage: {sys.argv[0]} preflight | upload LOCAL_FILE REMOTE_NAME")

    for setting in ("FTP_UPLOAD_URL", "FTP_USERNAME", "FTP_PASSWORD"):
        if not os.environ.get(setting):
            raise ValueError(f"Missing required setting: {setting}")
    if not os.environ["FTP_UPLOAD_URL"].startswith("ftp://"):
        raise ValueError("FTP_UPLOAD_URL must use ftp:// for explicit FTPS.")
    upload_url = os.environ["FTP_UPLOAD_URL"].removesuffix("/") + "/"

    ftp = [
        "curl", "--disable", "--silent", "--show-error", "--globoff",
        "--proto", "=ftp", "--ssl-reqd", "--insecure", "--ftp-pasv",
        "--ftp-method", "singlecwd", "--retry", "4", "--retry-all-errors",
        "--connect-timeout", "30", "--speed-limit", "1", "--speed-time", "120",
        "--user", f"{os.environ['FTP_USERNAME']}:{os.environ['FTP_PASSWORD']}",
    ]

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        pending = set()
        if preflight:
            source = work / "probe"
            name = f"_preflight-{work.name}.bin"
            download_url = os.environ["DOWNLOAD_BASE_URL"].removesuffix("/")
            pending.add(name)
        temporary = f".{name}.{work.name}.part"

        try:
            for phase in ("initial", "replacement"):
                if preflight:
                    source.write_bytes(os.urandom(1024 * 1024))
                pending.add(temporary)
                print(f"Uploading {name}", flush=True)
                subprocess.run(ftp + [
                    "--upload-file", str(source), "--quote", f"-RNFR {temporary}",
                    "--quote", f"-RNTO {name}", upload_url + temporary,
                ], check=True)
                pending.remove(temporary)
                if not preflight:
                    return

                subprocess.run([
                    "curl", "--disable", "--silent", "--show-error", "--globoff",
                    "--fail", "--location", "--retry", "4", "--retry-all-errors",
                    "--retry-max-time", "630", "--proto", "=https",
                    "--proto-redir", "=https", "--connect-timeout", "30",
                    "--max-time", "120", "--header", "Cache-Control: no-cache",
                    "--output", str(work / "download"),
                    f"{download_url}/{name}?check={phase}",
                ], check=True)
                if not filecmp.cmp(source, work / "download", shallow=False):
                    raise ValueError("HTTPS download does not match the uploaded probe.")
            subprocess.run(ftp + [
                "--connect-timeout", "10", "--max-time", "20", "--head",
                "--quote", f"+DELE {name}", "--output", os.devnull, upload_url,
            ], check=True)
            pending.remove(name)
            print("Upload and download checks passed.")
        finally:
            for name in pending:
                try:
                    subprocess.run(ftp + [
                        "--retry", "0", "--connect-timeout", "10", "--max-time", "20",
                        "--head", "--quote", f"+DELE {name}", "--output", os.devnull,
                        upload_url,
                    ], check=True)
                except (OSError, subprocess.CalledProcessError):
                    print(f"Could not remove temporary remote file: {name}", file=sys.stderr)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
    except subprocess.CalledProcessError:
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
