#!/usr/bin/env bash
set -euo pipefail

echo "Installing Windscribe..."

TMP_RPM="$(mktemp --suffix=.rpm)"
trap 'rm -f "${TMP_RPM}"' EXIT

# This URL is Windscribe's own "always current" download link for the
# Fedora/RPM x64 build. It 302-redirects to whatever the current release's
# rpm happens to be named (the filename/version changes every release), so
# we never hardcode a filename here — curl just follows the redirect.
curl -fL --retry 3 --retry-delay 2 \
  -o "${TMP_RPM}" \
  "https://windscribe.com/install/desktop/linux_rpm_x64"

# Sanity check: make sure we actually got an RPM back and not an HTML
# landing/error page (which would happen if Windscribe ever changes this
# endpoint to require JS or a browser user-agent). Fail loudly instead of
# baking garbage into the image.
if ! file "${TMP_RPM}" | grep -qi 'RPM'; then
  echo "ERROR: the file downloaded from Windscribe is not an RPM package." >&2
  echo "Windscribe's install-link behavior may have changed. First 500 bytes:" >&2
  head -c 500 "${TMP_RPM}" >&2
  exit 1
fi

# Import Windscribe's official signing key so the package can be verified.
rpm --import https://windscribe.com/windscribe_linux_signing_key.pub

dnf5 install -y "${TMP_RPM}"

echo "Windscribe installed successfully."
