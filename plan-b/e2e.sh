#!/bin/bash
# Local end-to-end smoke test for the tart (Plan B) backend.
#
# Registers a HOST-side runner with a tart:// label and runs exactly one job in
# a disposable macOS VM. Run this on a real Apple Silicon Mac with tart
# installed; trigger a `runs-on: <LABEL>` job in Forgejo, then run this.
#
# Required env:
#   FTR_FORGEJO_URL   Forgejo URL, reachable from BOTH host and VM (not localhost)
#   FTR_REG_TOKEN     a runner registration token from that Forgejo
# Optional:
#   FTR_BIN     path to the tart-enabled binary (default dist/forgejo-runner-tart)
#   FTR_LABEL   label name workflows use in runs-on (default tart-macos)
#   FTR_IMAGE   base VM image to clone (default ghcr.io/cirruslabs/macos-tahoe-base:latest)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${FTR_BIN:-$REPO_ROOT/dist/forgejo-runner-tart}"
: "${FTR_FORGEJO_URL:?set FTR_FORGEJO_URL (must be reachable from the VM, not localhost)}"
: "${FTR_REG_TOKEN:?set FTR_REG_TOKEN (runner registration token)}"
LABEL="${FTR_LABEL:-tart-macos}"
IMAGE="${FTR_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
NAME="${FTR_NAME:-mac-tart-smoke}"

command -v tart >/dev/null || { echo "tart not installed" >&2; exit 1; }
[ -x "$BIN" ] || { echo "missing $BIN (run plan-b/build.sh first)" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "[e2e] registering host runner '$NAME' label '${LABEL}:tart://${IMAGE}'"
"$BIN" register --no-interactive --instance "$FTR_FORGEJO_URL" \
  --token "$FTR_REG_TOKEN" --name "$NAME" --labels "${LABEL}:tart://${IMAGE}"

cat > config.yaml <<'EOF'
log:
  level: info
runner:
  file: .runner
  capacity: 1
cache:
  enabled: false
EOF

echo "[e2e] waiting for one '${LABEL}' job; it will run in a fresh tart VM, then exit"
exec "$BIN" one-job --wait --config config.yaml
