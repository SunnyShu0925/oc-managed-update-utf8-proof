#!/usr/bin/env bash
# Managed-update proof for PR #186033 (strict UTF-8 decoding of managed update
# handoff output), on a GitHub-hosted Ubuntu VM with a real systemd user manager.
#
#   Run A: published stable 2026.10.8 (driver without the fix) -> candidate 2026.10.9
#   Run B: installed candidate 2026.10.9 (driver with the fix)  -> 2026.10.10
#
# Both runs inject one raw 0xFF byte into the managed updater's --json stdout
# through a NODE_OPTIONS preload, so the handoff decoder is the only thing that
# differs between the two drivers.
set -uo pipefail

STABLE="${STABLE_VERSION:-2026.10.8}"
CAND_A="${CAND_A_VERSION:-2026.10.9}"
CAND_B="${CAND_B_VERSION:-2026.10.10}"
ASSET_BASE="${ASSET_BASE:-https://github.com/SunnyShu0925/oc-managed-update-utf8-proof/releases/download/v1}"
PORT=18833
TOKEN=proof-token-186033
WORK=/tmp/proof186033
SUMMARY=/tmp/proof-summary.txt
mkdir -p "$WORK"
: >"$SUMMARY"

say() { echo; echo "=== $* ==="; }
note() { echo "$*" | tee -a "$SUMMARY"; }
section() { say "$*"; echo "--- $* ---" >>"$SUMMARY"; }

section "environment"
{
  uname -a
  systemctl --version | head -1
  node --version
  echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
  echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"
  systemctl --user is-system-running || true
} 2>&1 | tee -a "$SUMMARY"
note "proof repository commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"

section "fetch reviewed candidate builds"
curl -fsSL -o "$WORK/cand-a.tgz" "$ASSET_BASE/openclaw-$CAND_A.tgz"
curl -fsSL -o "$WORK/cand-b.tgz" "$ASSET_BASE/openclaw-$CAND_B.tgz"
sha256sum "$WORK/cand-a.tgz" "$WORK/cand-b.tgz" | tee -a "$SUMMARY"
tar -xzOf "$WORK/cand-a.tgz" package/package.json >"$WORK/manifest-a.json"
tar -xzOf "$WORK/cand-b.tgz" package/package.json >"$WORK/manifest-b.json"
for version in "$CAND_A" "$CAND_B" "$STABLE"; do :; done
note "candidate A package version: $(node -p "require('$WORK/manifest-a.json').version")"
note "candidate B package version: $(node -p "require('$WORK/manifest-b.json').version")"

section "assert the reviewed build contains the fix"
FIX_A=$(tar -xzOf "$WORK/cand-a.tgz" package/dist/update-managed-service-handoff-current-*.mjs \
  | grep -c "retained a lossy copy")
FIX_B=$(tar -xzOf "$WORK/cand-b.tgz" package/dist/update-managed-service-handoff-current-*.mjs \
  | grep -c "retained a lossy copy")
note "candidate A fix markers in shipped dist: $FIX_A"
note "candidate B fix markers in shipped dist: $FIX_B"

section "install published stable driver $STABLE"
npm install -g "openclaw@$STABLE" --no-audit --no-fund 2>&1 | tail -3
OPENCLAW="$HOME/.npm-global/bin/openclaw"
note "published driver: $("$OPENCLAW" --version 2>&1)"
BASE_MARKERS=$(grep -c "retained a lossy copy" \
  "$HOME"/.npm-global/lib/node_modules/openclaw/dist/update-managed-service-handoff-current-*.mjs 2>/dev/null || true)
note "published driver fix markers in shipped dist: ${BASE_MARKERS:-0}"

section "start loopback registries for the candidates"
PROOF_REGISTRY_PORT=48771 PROOF_TARBALL="$WORK/cand-a.tgz" \
PROOF_CANDIDATE_VERSION="$CAND_A" PROOF_BASE_VERSION="$STABLE" \
PROOF_CANDIDATE_MANIFEST="$WORK/manifest-a.json" PROOF_REGISTRY_LOG=/tmp/registry-a.log \
  node scripts/registry-proxy.mjs >/tmp/registry-a.out 2>&1 &
PROOF_REGISTRY_PORT=48772 PROOF_TARBALL="$WORK/cand-b.tgz" \
PROOF_CANDIDATE_VERSION="$CAND_B" PROOF_BASE_VERSION="$STABLE" \
PROOF_CANDIDATE_MANIFEST="$WORK/manifest-b.json" PROOF_REGISTRY_LOG=/tmp/registry-b.log \
  node scripts/registry-proxy.mjs >/tmp/registry-b.out 2>&1 &
for port in 48771 48772; do
  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/openclaw" && break
    sleep 1
  done
done
for port in 48771 48772; do
  curl -s "http://127.0.0.1:$port/openclaw" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
  const doc = JSON.parse(raw);
  const version = doc["dist-tags"].latest;
  const entry = doc.versions[version];
  console.log(`registry latest=${version} schemaVersions=${JSON.stringify(entry.openclaw?.schemaVersions)}`);
});
' | tee -a "$SUMMARY"
done

section "seed operator state (settings, workspace data)"
mkdir -p "$HOME/.openclaw/workspace"
cat >"$HOME/.openclaw/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "bind": "loopback", "port": $PORT, "auth": { "mode": "token", "token": "$TOKEN" } },
  "agents": { "defaults": { "workspace": "$HOME/.openclaw/workspace" }, "entries": { "main": {} } },
  "logging": { "level": "info" }
}
JSON
chmod 600 "$HOME/.openclaw/openclaw.json"
echo "proof-data-marker-186033" >"$HOME/.openclaw/workspace/PROOF_MARKER.txt"
note "settings sha256: $(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"

section "install and start the managed gateway service"
"$OPENCLAW" gateway install --port "$PORT" --token "$TOKEN" --json 2>&1 | tail -6
for _ in $(seq 1 90); do
  "$OPENCLAW" gateway status --json >/tmp/gateway-status.json 2>/dev/null || true
  node -e 'const s=require("/tmp/gateway-status.json");process.exit(s?.service?.runtime?.status==="running"?0:1)' 2>/dev/null && break
  sleep 2
done
node -e '
const s = require("/tmp/gateway-status.json");
console.log(`service=${s?.service?.runtime?.status} managerUid=${s?.service?.runtime?.systemd?.managerUid} unit=${s?.service?.runtime?.systemd?.unit}`);
' | tee -a "$SUMMARY"

section "seed a cron job through the shipped CLI"
"$OPENCLAW" cron add --every 1d --agent main --message "proof turn" \
  --display-name proof-job --json 2>&1 | tail -3
"$OPENCLAW" cron list --json >/tmp/cron-before.json 2>/dev/null || true
node -e '
const jobs = require("/tmp/cron-before.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
console.log(`cron before: ${list.length} job(s) ${list.map((job) => job.name ?? job.displayName ?? job.id).join(",")}`);
' | tee -a "$SUMMARY"

run_managed_update() {
  local label="$1" registry="$2" inject_log="$3" out_json="$4" out_err="$5"
  local before_dirs after_dirs handoff
  before_dirs=$(ls -d /tmp/openclaw-update-run-handoff-* 2>/dev/null | sort || true)
  : >"$inject_log"
  local rc=0
  NODE_OPTIONS="--import file://$PWD/scripts/inject-utf8.mjs" \
  PROOF_INJECT_LOG="$inject_log" \
  NPM_CONFIG_REGISTRY="http://127.0.0.1:$registry" \
  OPENCLAW_UPDATE_PACKAGE_SPEC=openclaw \
    "$OPENCLAW" update --yes --json --timeout 1200 >"$out_json" 2>"$out_err" || rc=$?
  LAST_UPDATE_RC=$rc
  note "$label update exit=$rc"
  echo "--- $label injector log ---"
  cat "$inject_log" 2>/dev/null
  cat "$inject_log" 2>/dev/null >>"$SUMMARY"
  after_dirs=$(ls -d /tmp/openclaw-update-run-handoff-* 2>/dev/null | sort || true)
  handoff=$(comm -13 <(printf '%s\n' "$before_dirs") <(printf '%s\n' "$after_dirs") | tail -1)
  if [ -z "$handoff" ]; then
    handoff=$(ls -dt /tmp/openclaw-update-run-handoff-* 2>/dev/null | head -1)
  fi
  note "$label handoff dir: ${handoff:-none}"
  if [ -n "$handoff" ] && [ -f "$handoff/handoff.log" ]; then
    echo "--- $label handoff.log invalid-UTF-8 lines: $(grep -c 'invalid UTF-8' "$handoff/handoff.log" 2>/dev/null || echo 0)"
    grep 'invalid UTF-8' "$handoff/handoff.log" 2>/dev/null | tee -a "$SUMMARY"
    echo "--- $label handoff.log command/helper lines ---"
    grep -E 'starting managed update command|update command pid|update command exited|helper completed' "$handoff/handoff.log" 2>/dev/null | tee -a "$SUMMARY"
    echo "--- $label handoff.log tail ---"
    tail -6 "$handoff/handoff.log" 2>/dev/null | cut -c1-300
  fi
  echo "--- $label update result ---"
  node -e '
const fs = require("node:fs");
const raw = fs.readFileSync(process.argv[1], "utf8");
let body;
try { body = JSON.parse(raw); } catch { console.log("unparseable result output"); process.exit(0); }
const steps = (body.run?.steps ?? body.steps ?? []).map((step) => `${step.step ?? step.name}:${step.status}`);
console.log(`status=${body.status ?? body.run?.status} reason=${body.reason ?? body.run?.reason ?? ""}`);
console.log(`steps=${steps.join(" -> ")}`);
console.log(`from=${body.currentVersion ?? ""} to=${body.targetVersion ?? ""} tag=${body.tag ?? ""}`);
console.log(`verification=${JSON.stringify(body.verification ?? body.run?.verification ?? {})}`);
' "$out_json" 2>&1 | tee -a "$SUMMARY"
  echo "--- $label stderr tail ---"
  tail -8 "$out_err" 2>/dev/null | cut -c1-300
}

verify_after() {
  local label="$1" expected="$2"
  local installed cron_rc=1 config_rc=1
  installed=$("$OPENCLAW" --version 2>&1)
  note "$label installed: $installed"
  case "$installed" in
    *"$expected"*) note "$label version check: PASS" ;;
    *) note "$label version check: FAIL (expected $expected)" ;;
  esac
  "$OPENCLAW" cron list --json >/tmp/cron-after.json 2>/dev/null || true
  node -e '
const jobs = require("/tmp/cron-after.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
const hit = list.find((job) => `${job.name ?? job.displayName ?? job.id ?? ""}`.includes("proof-job"));
console.log(`cron after: ${list.length} job(s) proof-job=${hit ? "present" : "MISSING"}`);
process.exit(hit ? 0 : 1);
' | tee -a "$SUMMARY"
  cron_rc=${PIPESTATUS[0]}
  node -e '
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.env.HOME + "/.openclaw/openclaw.json", "utf8"));
console.log(`config gateway.port=${config.gateway?.port} logging.level=${config.logging?.level} workspace=${config.agents?.defaults?.workspace}`);
process.exit(config.gateway?.port === 18833 ? 0 : 1);
' | tee -a "$SUMMARY"
  config_rc=${PIPESTATUS[0]}
  note "$label settings sha256: $(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"
  note "$label workspace marker: $(cat "$HOME/.openclaw/workspace/PROOF_MARKER.txt" 2>/dev/null)"
  "$OPENCLAW" gateway status --json >/tmp/gateway-status-after.json 2>/dev/null || true
  node -e '
const s = require("/tmp/gateway-status-after.json");
console.log(`service after=${s?.service?.runtime?.status} version=${s?.service?.runtime?.version ?? s?.rpc?.version ?? "n/a"} pid=${s?.service?.runtime?.pid ?? "n/a"}`);
' | tee -a "$SUMMARY"
  [ "$cron_rc" -eq 0 ] && [ "$config_rc" -eq 0 ]
}

section "RUN A: published stable $STABLE -> candidate $CAND_A (driver without the fix)"
LAST_UPDATE_RC=0
run_managed_update "runA" 48771 /tmp/inject-a.log /tmp/update-a.json /tmp/update-a.err
A_RC=$LAST_UPDATE_RC
A_OK=no
verify_after "runA" "$CAND_A" && A_OK=yes

section "RUN B: installed candidate $CAND_A (driver with the fix) -> $CAND_B"
run_managed_update "runB" 48772 /tmp/inject-b.log /tmp/update-b.json /tmp/update-b.err
B_RC=$LAST_UPDATE_RC
B_OK=no
verify_after "runB" "$CAND_B" && B_OK=yes

section "verdict"
NEWEST_HANDOFF=$(ls -dt /tmp/openclaw-update-run-handoff-* 2>/dev/null | head -1)
B_WARN_TOTAL=0
if [ -n "$NEWEST_HANDOFF" ]; then
  B_WARN_TOTAL=$(grep -c 'invalid UTF-8' "$NEWEST_HANDOFF/handoff.log" 2>/dev/null || echo 0)
fi
note "verdict inputs: runAExit=$A_RC runAVerify=$A_OK runBExit=$B_RC runBVerify=$B_OK latestHandoffWarnings=$B_WARN_TOTAL"
echo "all handoff warning lines across runs:"
grep -H 'invalid UTF-8' /tmp/openclaw-update-run-handoff-*/handoff.log 2>/dev/null | tee -a "$SUMMARY" || true
note "VERDICT=$([ "$A_OK" = yes ] && [ "$B_OK" = yes ] && [ "$B_WARN_TOTAL" -ge 1 ] && echo PASS || echo FAIL)"
