#!/usr/bin/env bash
set -euo pipefail

echo "Installing Windscribe..."

API_URL="https://api.github.com/repos/Windscribe/Desktop-App/releases/latest"

# Find the GUI (not CLI-only) Fedora amd64 rpm asset from the latest
# GitHub release. This avoids windscribe.com's "smart" install link, which
# does not reliably return the full rpm (it can return a small stub/page
# instead — confirmed by a prior failed build where it returned ~73KB
# instead of the tens-of-MB real package).
DOWNLOAD_URL="$(
  curl -fsSL "${API_URL}" \
    | grep -oE '"browser_download_url": *"[^"]+"' \
    | sed -E 's/.*"(https:[^"]+)"/\1/' \
    | grep -E '/windscribe_[^/]*_amd64_fedora\.rpm$' \
    | head -n1
)"

if [ -z "${DOWNLOAD_URL}" ]; then
  echo "ERROR: could not find a Fedora amd64 .rpm asset in Windscribe's latest GitHub release." >&2
  echo "Check https://github.com/Windscribe/Desktop-App/releases/latest manually." >&2
  exit 1
fi

echo "Downloading: ${DOWNLOAD_URL}"

TMP_RPM="$(mktemp --suffix=.rpm)"
trap 'rm -f "${TMP_RPM}"' EXIT

curl -fL --retry 3 --retry-delay 2 -o "${TMP_RPM}" "${DOWNLOAD_URL}"

# Verify this is a genuine, parseable RPM header — not just a file that
# superficially looks rpm-like. rpm -qp fails loudly on anything truncated,
# corrupted, or not actually an rpm.
if ! rpm -qp --nosignature "${TMP_RPM}" &>/dev/null; then
  echo "ERROR: downloaded file is not a valid RPM package." >&2
  ls -la "${TMP_RPM}" >&2
  file "${TMP_RPM}" >&2 || true
  exit 1
fi

# Belt-and-braces: the real client is tens of MB. Anything under 1MB is
# almost certainly a stub/error page, not the actual installer.
MIN_SIZE=1000000
ACTUAL_SIZE="$(stat -c%s "${TMP_RPM}")"
if [ "${ACTUAL_SIZE}" -lt "${MIN_SIZE}" ]; then
  echo "ERROR: downloaded Windscribe rpm is suspiciously small (${ACTUAL_SIZE} bytes), refusing to install." >&2
  exit 1
fi

# Import Windscribe's official signing key so the package can be verified.
rpm --import https://windscribe.com/windscribe_linux_signing_key.pub

dnf5 install -y "${TMP_RPM}"

echo "Windscribe installed successfully."
