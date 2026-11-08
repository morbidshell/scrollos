#!/usr/bin/env bash
# Download the OpenSnitch and Windscribe RPMs (and Windscribe's signing key) into a
# directory that the Containerfile then consumes.
#
#   GH_TOKEN=... bash scripts/fetch-rpms.sh [outdir]        # default outdir: rpms
#
# Uses the GitHub CLI (preinstalled on GitHub-hosted runners), which talks to the
# authenticated API instead of scraping github.com/.../releases/latest, the endpoint
# that kept answering 504 from the runners. Needs GH_TOKEN (in Actions: ${{ github.token }}).
#
# Pin a version instead of taking the latest release:
#   OPENSNITCH_VERSION=1.8.0 WINDSCRIBE_VERSION=2.24.13 bash scripts/fetch-rpms.sh
set -euo pipefail

out="${1:-rpms}"
rm -rf "${out}"
mkdir -p "${out}"

# Retry with growing pauses (10s, 20s, ... 60s). GitHub's 504s have come in bursts.
retry() {
    local n
    for n in 1 2 3 4 5 6; do
        "$@" && return 0
        echo "attempt ${n} failed: $*" >&2
        [ "${n}" -lt 6 ] && sleep $((n * 10))
    done
    return 1
}

# gh takes the tag as an optional first argument; empty means "latest release".
tag() { [ -z "${1:-}" ] || [ "$1" = latest ] || echo "v$1"; }

retry gh release download $(tag "${OPENSNITCH_VERSION:-}") --repo evilsocket/opensnitch \
    --dir "${out}" --pattern 'opensnitch-*.x86_64.rpm' --pattern 'opensnitch-ui-*.noarch.rpm'
retry gh release download $(tag "${WINDSCRIBE_VERSION:-}") --repo Windscribe/Desktop-App \
    --dir "${out}" --pattern 'windscribe_*_amd64_fedora.rpm'
retry curl -fsSL -o "${out}/windscribe_linux_signing_key.pub" \
    https://windscribe.com/windscribe_linux_signing_key.pub

# Each pattern must have matched exactly one file, or the build would pick the wrong RPM.
for pat in 'opensnitch-[0-9]*.x86_64.rpm' 'opensnitch-ui-*.noarch.rpm' 'windscribe_*_amd64_fedora.rpm'; do
    n=$(find "${out}" -maxdepth 1 -name "${pat}" | wc -l)
    [ "${n}" -eq 1 ] || { echo "expected exactly 1 file matching ${pat}, found ${n}" >&2; ls -l "${out}" >&2; exit 1; }
done
[ -s "${out}/windscribe_linux_signing_key.pub" ] || { echo "signing key is empty" >&2; exit 1; }

ls -l "${out}"
