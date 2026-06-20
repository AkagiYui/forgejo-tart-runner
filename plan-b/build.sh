#!/bin/bash
# Build forgejo-runner WITH the tart backend, using the rebase-based fork model:
# clone an upstream release tag, replay our patch series onto it (git am), build.
#
#   ./plan-b/build.sh [UPSTREAM_TAG]      # default: v12.12.0 (the patch base)
#
# Env overrides: FTR_UPSTREAM, FTR_TAG, FTR_WORKDIR, FTR_OUT.
# If `git am` fails, the patches no longer apply cleanly to that tag and need a
# manual refresh (see README "升级/同步上游").
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${FTR_UPSTREAM:-https://code.forgejo.org/forgejo/runner}"
TAG="${1:-${FTR_TAG:-v12.12.0}}"
WORKDIR="${FTR_WORKDIR:-$REPO_ROOT/plan-b/.build}"
OUT="${FTR_OUT:-$REPO_ROOT/dist/forgejo-runner-tart}"

log() { echo "[build] $*"; }

log "upstream=$UPSTREAM tag=$TAG"
rm -rf "$WORKDIR"
git clone --quiet --depth 1 --branch "$TAG" "$UPSTREAM" "$WORKDIR"

cd "$WORKDIR"
# git am needs an author identity.
git config user.email "ci@forgejo-tart-runner.local"
git config user.name  "forgejo-tart-runner"

log "applying $(ls "$REPO_ROOT"/plan-b/patches/*.patch | wc -l | tr -d ' ') patch(es) onto $TAG"
if ! git am "$REPO_ROOT"/plan-b/patches/*.patch; then
  git am --abort || true
  echo "[build] ERROR: patches do not apply cleanly onto $TAG." >&2
  echo "[build] Refresh them: apply manually, resolve, then regenerate with" >&2
  echo "[build]   git format-patch <tag> -o $REPO_ROOT/plan-b/patches" >&2
  exit 1
fi

log "go build -> $OUT"
mkdir -p "$(dirname "$OUT")"
GOTOOLCHAIN=local go build -o "$OUT" .
file "$OUT"
log "done: built from $TAG + tart patch series"
