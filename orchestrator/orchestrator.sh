#!/bin/bash
# forgejo-tart-runner orchestrator (Plan A: runner-inside-VM).
#
# For each job, this host-side loop:
#   1. clones a clean base macOS VM (tart clone, copy-on-write, ~instant)
#   2. boots it headless with the runner payload mounted read-only
#   3. runs `forgejo-runner one-job` inside the VM via `tart exec`
#      (the runner waits for a task, runs it on the host backend, then exits)
#   4. destroys the clone (tart stop + delete)
#
# Result: every Forgejo Actions job runs in a pristine, disposable macOS VM.
#
# The runner itself never talks to tart — the runner inside the VM is the
# stock forgejo-runner. All VM lifecycle is driven here, via the tart CLI.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- configuration (override via environment) ----
BASE_IMAGE="${FTR_BASE_IMAGE:-tahoe-base}"               # base VM to clone (needs git + node)
BIN="${FTR_BIN:-$REPO_ROOT/dist/forgejo-runner}"         # darwin/arm64 runner binary
CONFIG="${FTR_CONFIG:-$REPO_ROOT/orchestrator/config.yaml}"
RUNNER_FILE="${FTR_RUNNER_FILE:-$REPO_ROOT/runtime/.runner}"   # registration (secrets)
GUEST_RUN="${FTR_GUEST_RUN:-$REPO_ROOT/orchestrator/guest-run.sh}"
VM_PREFIX="${FTR_VM_PREFIX:-ftr-job}"
LOOP="${FTR_LOOP:-1}"                                     # 1 = keep cycling, 0 = one job then exit
BOOT_TIMEOUT="${FTR_BOOT_TIMEOUT:-120}"                  # seconds to wait for guest agent

log() { echo "[orchestrator $(date '+%H:%M:%S')] $*"; }

# Stop and delete a VM clone, tolerating a still-running `tart run` process.
cleanup_vm() {
  local name="$1" runpid="${2:-}"
  tart stop "$name" --timeout 15 >/dev/null 2>&1 || true
  if [ -n "$runpid" ]; then
    local i
    for i in $(seq 1 20); do kill -0 "$runpid" 2>/dev/null || break; sleep 1; done
    kill "$runpid" 2>/dev/null || true
  fi
  local i
  for i in $(seq 1 10); do
    tart delete "$name" >/dev/null 2>&1 && return 0
    sleep 1
  done
  tart delete "$name" >/dev/null 2>&1 || true
}

run_one() {
  local ts name payload runpid rc=0 ready=0 i
  ts="$(date '+%Y%m%d-%H%M%S')-$$-${RANDOM}"
  name="${VM_PREFIX}-${ts}"

  # Assemble the payload mounted read-only into the VM.
  payload="$(mktemp -d /tmp/ftr-payload.XXXXXX)"
  cp "$BIN" "$payload/forgejo-runner"
  cp "$CONFIG" "$payload/config.yaml"
  cp "$RUNNER_FILE" "$payload/.runner"
  cp "$GUEST_RUN" "$payload/guest-run.sh"
  chmod +x "$payload/forgejo-runner" "$payload/guest-run.sh"

  log "clone $BASE_IMAGE -> $name"
  if ! tart clone "$BASE_IMAGE" "$name"; then
    log "ERROR: clone failed"; rm -rf "$payload"; return 1
  fi

  log "boot $name (headless, payload mounted ro)"
  tart run --no-graphics --dir="payload:${payload}:ro" "$name" >"/tmp/${name}.run.log" 2>&1 &
  runpid=$!

  # Wait for the tart guest agent to come up.
  for i in $(seq 1 $((BOOT_TIMEOUT / 2))); do
    if tart exec "$name" true 2>/dev/null; then ready=1; break; fi
    if ! kill -0 "$runpid" 2>/dev/null; then break; fi
    sleep 2
  done
  if [ "$ready" != 1 ]; then
    log "ERROR: guest agent not ready within ${BOOT_TIMEOUT}s; run log:"
    cat "/tmp/${name}.run.log" 2>/dev/null || true
    cleanup_vm "$name" "$runpid"; rm -rf "$payload"; return 1
  fi

  log "guest ready; running one-job inside $name"
  set +e
  tart exec "$name" bash -lc 'bash "/Volumes/My Shared Files/payload/guest-run.sh"'
  rc=$?
  set -e
  log "one-job exited rc=$rc; destroying $name"

  cleanup_vm "$name" "$runpid"
  rm -rf "$payload"
  rm -f "/tmp/${name}.run.log"
  return "$rc"
}

# ---- preflight ----
command -v tart >/dev/null || { echo "ERROR: tart not found in PATH" >&2; exit 1; }
for f in "$BIN" "$CONFIG" "$RUNNER_FILE" "$GUEST_RUN"; do
  [ -f "$f" ] || { echo "ERROR: missing required file: $f" >&2; exit 1; }
done
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$BASE_IMAGE" \
  || { echo "ERROR: base image '$BASE_IMAGE' not found (tart list)" >&2; exit 1; }

log "base=$BASE_IMAGE loop=$LOOP bin=$BIN"
if [ "$LOOP" = 1 ]; then
  while true; do
    run_one || log "iteration failed; retrying in 5s"
    sleep 5
  done
else
  run_one
fi
