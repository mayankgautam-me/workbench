#!/usr/bin/env bash
# project-standard v1.6 (managed: refresh with the project-standard skill, put project changes in make/local.mk)
#
# Signs one Windows file with the project's code-signing certificate. The app-tauri release helper passes it to Tauri as
# bundle.windows.signCommand (`bash <this> %1`, only when the secrets hold keys/windows-codesign), so Tauri calls it once
# per binary and installer. The certificate (a PFX) is the key file keys/windows-codesign; its password is the staging
# variable WINDOWS_CERT_PASSWORD (secrets.schema). Both reach signtool through secrets.sh, never as a file in the project.
# Timestamp server: WINDOWS_TIMESTAMP_URL (default http://timestamp.digicert.com). signtool comes from the Windows SDK.
#
#   sign-windows.sh FILE

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: sign-windows.sh FILE" >&2
  exit 2
fi
file=$1
bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# signtool.exe of the newest Windows SDK (x64); the runner image ships the SDK under Windows Kits
signtool=$(find "/c/Program Files (x86)/Windows Kits/10/bin" -path '*/x64/signtool.exe' 2>/dev/null | sort | tail -n 1 || true)
if [ -z "$signtool" ]; then
  echo "sign-windows: signtool.exe not found under Program Files (x86)/Windows Kits/10/bin" >&2
  exit 1
fi
ts=${WINDOWS_TIMESTAMP_URL:-http://timestamp.digicert.com}

# Git Bash turns /fd, /f ... into Windows paths when it starts signtool: MSYS2_ARG_CONV_EXCL keeps the switches, and cygpath -w
# gives signtool the Windows paths of the PFX and the file. Trade-off: signtool takes the password only as /p, so it is
# on the command line of signtool while it runs (visible to processes of the same user on the runner). The CI job is the
# only place it exists; it is in the staging env, never in the project.
# the password comes from the staging env (exec exports it), the PFX from its key file (with-file, a mode-600 temp file)
exec bash "$bin_dir/secrets.sh" exec --env staging -- env WINDOWS_SIGNTOOL="$signtool" WINDOWS_TIMESTAMP_URL="$ts" \
  bash "$bin_dir/secrets.sh" with-file windows-codesign -- \
  bash -c 'MSYS2_ARG_CONV_EXCL="*" "$WINDOWS_SIGNTOOL" sign /fd SHA256 /f "$(cygpath -w "$1")" /p "$WINDOWS_CERT_PASSWORD" /tr "$WINDOWS_TIMESTAMP_URL" /td SHA256 "$(cygpath -w "$2")"' \
  sign {} "$file"
