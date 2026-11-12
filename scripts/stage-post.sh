#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Background mode: the session must end when the job ends, also after a
# failure or a cancel. A composite action has no post step of its own, but
# the post step of an action it uses does run then. `uses:` cannot name a
# path inside this action (github.action_path is not allowed there), only a
# path relative to the workspace: so the helper in post/ is copied next to
# the checkout (the runner's folder for this repository, never inside the
# checkout itself) and action.yml uses it as ./../.via-cicd-post.
#
# Two background sessions in one job share the copy: it is the same helper,
# and each post step gets its own session's inputs.

ws="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
if command -v cygpath >/dev/null 2>&1; then ws=$(cygpath -u "$ws"); fi
dest="$(dirname "$ws")/.via-cicd-post"
src="${SCRIPTS_DIR}/../post"

rm -rf "$dest"
mkdir -p "$dest"
cp -p "$src/action.yml" "$src/main.js" "$src/post.js" "$dest/"
echo "The session ends at the end of the job (post step)."
