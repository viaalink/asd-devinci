#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Installs the Viaalink CLI with the official installer, the same way the
# CLI's own terminal workflow does. REQUESTED_VERSION: latest, a release tag
# or a nightly tag.
#
# The install is the job's own: the binaries go to CLI_DIR/bin and the CLI's
# data directory (helpers, modules, its project list) to CLI_DIR/home, both in
# this session's state directory under RUNNER_TEMP. A self-hosted runner's own
# CLI (~/.local/bin/via and ~/.local/share/via) is never replaced, so other
# jobs on that runner keep the CLI they had. The job's PATH and ASD_HOME
# (and VIA_HOME, which the installer and the CLI prefer when it is set) point
# at this install for the rest of the job, the caller's later steps included.
# The CLI's config directory (relay registry; the CLI moves ~/.config/asd to
# ~/.config/via on every start, the installer's `via --version` included)
# follows XDG_CONFIG_HOME: every step of the action, this one too, sets it to
# CLI_DIR/config (action.yml), not the job, so the caller's later steps keep
# their own ~/.config (gh, git).

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
  ci_error "cli-version is not a valid nightly tag; expected vX.Y.Z-nightly.YYYYMMDDTHHMM"
  exit 1
fi

if [ -z "${STATE_DIR:-}" ]; then
  ci_error "No session state directory: the credentials step did not run."
  exit 1
fi
CLI_DIR="${STATE_DIR}/cli"
CLI_BIN="${CLI_DIR}/bin"
CLI_HOME="${CLI_DIR}/home"
mkdir -p "$CLI_BIN" "$CLI_HOME" "${CLI_DIR}/config"

# Separate bin and home: the installer moves the binary into <home>/bin and
# links it from INSTALL_DIR. ASD_NO_MODIFY_PATH: no shell profile edits.
curl -fsSL https://raw.githubusercontent.com/viaalink/cli/main/install.sh \
  | VERSION="$VERSION" VIA_INSTALL_BASE_URL="$VIA_INSTALL_BASE_URL" \
    INSTALL_DIR="$CLI_BIN" ASD_HOME="$CLI_HOME" VIA_HOME="$CLI_HOME" \
    ASD_NO_MODIFY_PATH=1 VIA_NO_MODIFY_PATH=1 bash

if [ ! -x "$CLI_BIN/via" ]; then
  ci_error "The installer finished but ${CLI_BIN}/via is not there."
  exit 1
fi
ci_add_path "$CLI_BIN"
ci_set_env ASD_HOME "$CLI_HOME"
ci_set_env VIA_HOME "$CLI_HOME"
echo "Installed for this job only: $(ASD_HOME="$CLI_HOME" VIA_HOME="$CLI_HOME" "$CLI_BIN/via" --version 2>/dev/null | tail -1) in ${CLI_DIR}"
