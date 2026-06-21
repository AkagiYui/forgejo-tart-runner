#!/bin/bash
# One-shot setup of the local dev/test environment for forgejo-tart-runner:
#   1. build the darwin/arm64 runner binary
#   2. bring up Forgejo in OrbStack/Docker (ROOT_URL = tart gateway)
#   3. create an admin user + mint an admin API token
#   4. obtain a runner registration token
#   5. create a test repo and push the example workflow
#   6. register the runner -> runtime/.runner
#
# Safe to re-run: steps that already exist are skipped.
#
# After this, start the orchestrator:   ./plan-a/orchestrator.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---- knobs (override via env) ----
HOST_IP="${FTR_HOST_IP:-192.168.64.1}"          # tart NAT gateway, reachable from VMs
FORGEJO_URL="http://${HOST_IP}:3000"
ADMIN_USER="${FTR_ADMIN_USER:-forge}"
ADMIN_PASS="${FTR_ADMIN_PASS:-ForgeTart#2026}"
ADMIN_EMAIL="${FTR_ADMIN_EMAIL:-forge@local}"
TEST_REPO="${FTR_TEST_REPO:-mac-ci}"
RUNNER_NAME="${FTR_RUNNER_NAME:-mac-tart-runner}"
RUNNER_LABELS="${FTR_RUNNER_LABELS:-macos:host}"

log() { echo "[setup] $*"; }

# 1. build runner -------------------------------------------------------------
if [ ! -x dist/forgejo-runner ]; then
  log "building dist/forgejo-runner (darwin/arm64)"
  ( cd sucai/forgejo-runner && GOTOOLCHAIN=local go build -o "$REPO_ROOT/dist/forgejo-runner" . )
else
  log "runner binary present"
fi

# 2. Forgejo up ---------------------------------------------------------------
log "starting Forgejo (docker compose)"
docker compose -f dev/docker-compose.yml up -d >/dev/null
log "waiting for Forgejo to become ready"
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:3000/api/v1/version)" = "200" ] && break
  sleep 1
done
curl -s http://localhost:3000/api/v1/version; echo

# 3. admin user + token -------------------------------------------------------
log "ensuring admin user '$ADMIN_USER'"
docker exec -u git forgejo-tart forgejo admin user create \
  --admin --username "$ADMIN_USER" --password "$ADMIN_PASS" --email "$ADMIN_EMAIL" \
  --must-change-password=false 2>/dev/null || log "(admin already exists)"

log "minting admin API token"
ATOKEN="$(docker exec -u git forgejo-tart forgejo admin user generate-access-token \
  --username "$ADMIN_USER" --scopes all --raw 2>/dev/null | tail -1)"
echo "$ATOKEN" > dev/.admin-token
H="Authorization: token $ATOKEN"

# 4. runner registration token ------------------------------------------------
log "fetching runner registration token"
REGTOK="$(curl -s -H "$H" "http://localhost:3000/api/v1/admin/runners/registration-token" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
echo "$REGTOK" > dev/.reg-token

# 5. test repo + workflow -----------------------------------------------------
log "ensuring repo $ADMIN_USER/$TEST_REPO"
curl -s -H "$H" -H "Content-Type: application/json" \
  -d "{\"name\":\"$TEST_REPO\",\"auto_init\":true,\"default_branch\":\"main\",\"private\":false}" \
  "http://localhost:3000/api/v1/user/repos" >/dev/null || true

log "pushing example workflow"
CONTENT_B64="$(base64 -i plan-a/ci.yml)"
python3 - "$ATOKEN" "$CONTENT_B64" "$ADMIN_USER" "$TEST_REPO" <<'PY' || true
import sys,json,urllib.request,urllib.error
token,content,owner,repo=sys.argv[1:5]
body=json.dumps({"message":"add macOS CI workflow","content":content,"branch":"main"}).encode()
req=urllib.request.Request(
  f"http://localhost:3000/api/v1/repos/{owner}/{repo}/contents/.dev/workflows/ci.yml",
  data=body,method="POST",
  headers={"Authorization":"token "+token,"Content-Type":"application/json"})
try:
  urllib.request.urlopen(req); print("[setup] workflow pushed")
except urllib.error.HTTPError as e:
  print("[setup] workflow exists or:", e.code)
PY

# 6. register runner ----------------------------------------------------------
if [ -f runtime/.runner ]; then
  log "runner already registered (runtime/.runner exists)"
else
  log "registering runner '$RUNNER_NAME' labels=$RUNNER_LABELS"
  mkdir -p runtime
  ( cd runtime && "$REPO_ROOT/dist/forgejo-runner" register --no-interactive \
      --instance "$FORGEJO_URL" --token "$REGTOK" \
      --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" )
fi

log "done.

  Forgejo:   $FORGEJO_URL   (admin: $ADMIN_USER / $ADMIN_PASS)
  Test repo: $FORGEJO_URL/$ADMIN_USER/$TEST_REPO

Start the orchestrator (clean macOS VM per job):

  ./plan-a/orchestrator.sh

Then trigger the workflow from the Forgejo UI (or it already ran on push)."
