#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

ci_group_start "Installing the Viaalink CLI ${ASD_VERSION:-latest}"

# Determine asset name based on OS/arch
case "${CI_RUNNER_OS}-${CI_RUNNER_ARCH}" in
  Linux-X64)   ASSET="asd-linux-x64.tar.gz" ;;
  Linux-ARM64) ASSET="asd-linux-arm64.tar.gz" ;;
  macOS-X64)   ASSET="asd-darwin-x64.tar.gz" ;;
  macOS-ARM64) ASSET="asd-darwin-arm64.tar.gz" ;;
  Windows-X64) ASSET="asd-windows-x64.zip" ;;
  *) ci_error "Unsupported platform: ${CI_RUNNER_OS}-${CI_RUNNER_ARCH}"; exit 1 ;;
esac

# Download from the public release repo (asset names still start with asd-)
VERSION="${ASD_VERSION:-latest}"
if [ "$VERSION" = "latest" ]; then
  DOWNLOAD_URL="https://github.com/viaalink/cli/releases/latest/download/${ASSET}"
else
  # Ensure version has 'v' prefix to match GitHub release tags
  case "$VERSION" in
    v*) TAG="$VERSION" ;;
    *)  TAG="v${VERSION}" ;;
  esac
  DOWNLOAD_URL="https://github.com/viaalink/cli/releases/download/${TAG}/${ASSET}"
fi

echo "Downloading: ${DOWNLOAD_URL}"

# Create temp directory
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [ "$CI_RUNNER_OS" = "Windows" ]; then
  # Windows: binaries go to %LOCALAPPDATA%/via/bin (the 3.2 data directory)
  curl -fsSL "${DOWNLOAD_URL}" -o "$TMPDIR/cli.zip"

  ASD_BIN_DIR="${LOCALAPPDATA}/via/bin"
  mkdir -p "$ASD_BIN_DIR"

  # Extract (zip may have top-level dir like asd-windows-x64/)
  unzip -q "$TMPDIR/cli.zip" -d "$TMPDIR/extract"
  # Handle both flat (bin/*) and nested (asd-windows-x64/bin/*) archive layouts
  if [ -d "$TMPDIR/extract/bin" ]; then
    cp "$TMPDIR/extract/bin/"* "$ASD_BIN_DIR/"
  else
    cp "$TMPDIR/extract/"*/bin/* "$ASD_BIN_DIR/"
  fi

  # The Windows archive ships asd.exe only; install.ps1 installs it under
  # both names, and so do we.
  if [ ! -f "$ASD_BIN_DIR/via.exe" ] && [ -f "$ASD_BIN_DIR/asd.exe" ]; then
    cp "$ASD_BIN_DIR/asd.exe" "$ASD_BIN_DIR/via.exe"
  fi

  ci_add_path "${ASD_BIN_DIR}"
  ci_set_env "ASD_BIN_DIR" "${ASD_BIN_DIR}"
  echo "Installed to ${ASD_BIN_DIR}"
else
  # Linux/macOS: binaries go to ~/.local/share/via/bin (the 3.2 data directory)
  curl -fsSL "${DOWNLOAD_URL}" -o "$TMPDIR/cli.tar.gz"

  # Determine the CLI's bin directory based on OS
  if [ "$CI_RUNNER_OS" = "macOS" ]; then
    ASD_BIN_DIR="${HOME}/Library/Application Support/via/bin"
  else
    ASD_BIN_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/via/bin"
  fi
  mkdir -p "$ASD_BIN_DIR"

  # Extract (--strip-components=1 removes top-level dir like asd-linux-x64/)
  mkdir -p "$TMPDIR/extract"
  tar -xzf "$TMPDIR/cli.tar.gz" -C "$TMPDIR/extract" --strip-components=1

  # Install to the CLI's bin directory (where it looks for helper binaries)
  # -P keeps `via` a symlink to `asd` instead of a second copy
  cp -P "$TMPDIR/extract/bin/"* "$ASD_BIN_DIR/"
  chmod +x "$ASD_BIN_DIR"/*

  # Add to PATH for direct execution
  ci_add_path "${ASD_BIN_DIR}"
  # Export for subsequent steps so the CLI knows where binaries are
  ci_set_env "ASD_BIN_DIR" "${ASD_BIN_DIR}"

  echo "Installed to ${ASD_BIN_DIR}"
fi

# macOS: ttyd from releases might need Homebrew version in some cases
# (the released binary should work, but keep this as fallback)
if [ "$CI_RUNNER_OS" = "macOS" ] && ! "${ASD_BIN_DIR}/ttyd" --version &>/dev/null; then
  echo "Installing ttyd via Homebrew as fallback..."
  brew install ttyd
  cp "$(which ttyd)" "$ASD_BIN_DIR/ttyd"
fi

# Verify installation
echo ""
echo "Verifying installation..."
echo "ASD_BIN_DIR: ${ASD_BIN_DIR}"
ls -la "$ASD_BIN_DIR"
# The scripts call `via`, which ships from Viaalink CLI 3.2 on.
if ! ls "${ASD_BIN_DIR}"/via* >/dev/null 2>&1; then
  ci_error "No 'via' binary in ${VERSION}. This action needs Viaalink CLI 3.2 or newer (asd-version: latest)."
  exit 1
fi
"${ASD_BIN_DIR}/via" --version 2>/dev/null || echo "via: installed"
"${ASD_BIN_DIR}/ttyd" --version 2>/dev/null || echo "ttyd: installed"
"${ASD_BIN_DIR}/caddy" version 2>/dev/null || echo "caddy: installed"

echo ""
echo "Viaalink CLI installed to ${ASD_BIN_DIR}"

ci_group_end
