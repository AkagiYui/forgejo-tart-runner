#!/bin/bash
# Runs INSIDE the macOS VM (invoked by the host via `tart exec`).
#
# Copies the read-only mounted payload to a VM-local working directory and runs
# exactly ONE job, then exits. The host orchestrator destroys the VM afterwards,
# so every job gets a pristine macOS environment.
set -euo pipefail

MOUNT="/Volumes/My Shared Files/payload"
WORK="$HOME/forgejo-tart-job"

echo "[guest] $(date '+%H:%M:%S') preparing $WORK"
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$MOUNT/forgejo-runner" "$WORK/forgejo-runner"
cp "$MOUNT/config.yaml"    "$WORK/config.yaml"
cp "$MOUNT/.runner"        "$WORK/.runner"
chmod +x "$WORK/forgejo-runner"
# Locally-built Go binaries are ad-hoc signed and not quarantined, but strip
# any quarantine flag defensively so Gatekeeper never blocks execution.
xattr -dr com.apple.quarantine "$WORK/forgejo-runner" 2>/dev/null || true

cd "$WORK"
echo "[guest] runner: $(./forgejo-runner --version 2>/dev/null || echo unknown)"
echo "[guest] host tools: git=$(command -v git || echo MISSING) node=$(command -v node || echo MISSING)"
echo "[guest] starting one-job (waits for a task, runs it, then exits)"

# --wait: block until the server assigns a task, run it, then exit 0.
exec ./forgejo-runner one-job --config config.yaml --wait
