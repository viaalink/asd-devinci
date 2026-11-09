#!/bin/bash
set -euo pipefail

# Installs the Viaalink CLI with the official installer, the same way the
# CLI's own terminal workflow does. REQUESTED_VERSION: latest, a release tag
# or a nightly tag.

REQUESTED_VERSION="${REQUESTED_VERSION:-latest}"
VERSION=""
[ "$REQUESTED_VERSION" = "latest" ] || VERSION="$REQUESTED_VERSION"

# A nightly is a prerelease on viaalink/cli-nightly, which the installer does
# not look up; its base-URL mode fetches the archive and SHA256SUMS.txt from
# that release instead. Only the exact tag form is accepted, so the input
# cannot point the base URL at another path.
VIA_INSTALL_BASE_URL=""
if [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}T[0-9]{4}$ ]]; then
  [[ "$VERSION" == v* ]] || VERSION="v$VERSION"
  VIA_INSTALL_BASE_URL="https://github.com/viaalink/cli-nightly/releases/download/${VERSION}"
elif [[ "$VERSION" == *-nightly.* ]]; then
  echo "::error::cli-version is not a valid nightly tag; expected vX.Y.Z-nightly.YYYYMMDDTHHMM"
  exit 1
fi

curl -fsSL https://raw.githubusercontent.com/viaalink/cli/main/install.sh \
  | VERSION="$VERSION" VIA_INSTALL_BASE_URL="$VIA_INSTALL_BASE_URL" bash
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
