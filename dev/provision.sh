#!/bin/bash
# Build a "golden" base VM image for the runner by ensuring git + node (the
# tools actions/checkout and most JS actions need) are present, then leaving the
# VM stopped so the orchestrator can clone it per job.
#
# The orchestrator clones this base copy-on-write for every job, so anything
# baked in here is shared (fast) and every job still starts pristine.
#
#   ./dev/provision.sh [SRC_IMAGE] [DST_IMAGE]
#
# Defaults: SRC=ghcr.io/cirruslabs/macos-tahoe-base:latest  DST=forgejo-tart-base
# If SRC is already a local image (e.g. tahoe-base) it is used directly.
set -euo pipefail

SRC="${1:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
DST="${2:-forgejo-tart-base}"
BOOT_TIMEOUT="${FTR_BOOT_TIMEOUT:-180}"

log() { echo "[provision] $*"; }

cleanup() {
  tart stop "$DST" --timeout 20 >/dev/null 2>&1 || true
  [ -n "${RUNPID:-}" ] && kill "$RUNPID" 2>/dev/null || true
}
trap cleanup EXIT

log "clone $SRC -> $DST"
tart clone "$SRC" "$DST"

log "boot $DST (headless)"
tart run --no-graphics "$DST" >"/tmp/provision-$DST.log" 2>&1 &
RUNPID=$!

log "waiting for guest agent"
ready=0
for i in $(seq 1 $((BOOT_TIMEOUT / 2))); do
  if tart exec "$DST" true 2>/dev/null; then ready=1; break; fi
  kill -0 "$RUNPID" 2>/dev/null || { log "VM died early"; cat "/tmp/provision-$DST.log"; exit 1; }
  sleep 2
done
[ "$ready" = 1 ] || { log "guest agent not ready"; exit 1; }

log "ensuring git + node inside the VM"
tart exec "$DST" bash -lc '
  set -e
  need_brew=0
  command -v git  >/dev/null || need_brew=1
  command -v node >/dev/null || need_brew=1
  if [ "$need_brew" = 1 ]; then
    if ! command -v brew >/dev/null; then
      echo "Homebrew not found in base image; install git/node manually." >&2
      exit 1
    fi
    command -v git  >/dev/null || brew install git
    command -v node >/dev/null || brew install node
  fi
  echo "git:  $(git --version)"
  echo "node: $(node --version)"
'

log "shutting down cleanly"
tart exec "$DST" bash -lc 'sudo shutdown -h now' >/dev/null 2>&1 || true
for i in $(seq 1 30); do kill -0 "$RUNPID" 2>/dev/null || break; sleep 1; done
trap - EXIT
cleanup

log "done. Base image '$DST' is ready."
log "Run the orchestrator with:  FTR_BASE_IMAGE=$DST ./plan-a/orchestrator.sh"
