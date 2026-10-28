#!/usr/bin/env bash
# Managed-service update proof for PR #186033 (strict UTF-8 decoding of the
# managed update handoff output), on a GitHub-hosted Ubuntu VM with real systemd.
#
#   Run A: published stable 2026.10.8 (driver without the fix) -> candidate 2026.10.9
#   Run B: installed candidate 2026.10.9 (driver with the fix)  -> 2026.10.10
#
# Both updates are started from a cron command job, so the updater runs inside the
# Gateway process tree exactly like a scheduled update. A NODE_OPTIONS preload adds
# one raw 0xFF byte to the managed updater's --json stdout, so the handoff decoder
# is the only thing that differs between the two drivers.
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

say "environment"
{
  uname -a
  systemctl --version | head -1
  node --version
  echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
  echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"
  systemctl --user is-system-running || true
  busctl --user list | grep -E "org.freedesktop.systemd1" || echo "systemd1 not on the user bus"
} 2>&1 | tee -a "$SUMMARY"
note "proof harness commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"

say "fetch reviewed candidate builds"
curl -fsSL -o "$WORK/cand-a.tgz" "$ASSET_BASE/openclaw-$CAND_A.tgz"
curl -fsSL -o "$WORK/cand-b.tgz" "$ASSET_BASE/openclaw-$CAND_B.tgz"
sha256sum "$WORK/cand-a.tgz" "$WORK/cand-b.tgz" | tee -a "$SUMMARY"
tar -xzOf "$WORK/cand-a.tgz" package/package.json >"$WORK/manifest-a.json"
tar -xzOf "$WORK/cand-b.tgz" package/package.json >"$WORK/manifest-b.json"
note "candidate A package version: $(node -p "require('$WORK/manifest-a.json').version")"
note "candidate B package version: $(node -p "require('$WORK/manifest-b.json').version")"

say "assert the reviewed build contains the fix"
FIX_A=$(tar -xzOf "$WORK/cand-a.tgz" --wildcards 'package/dist/update-managed-service-handoff-current-*.mjs' |
  grep -c "retained a lossy copy")
FIX_B=$(tar -xzOf "$WORK/cand-b.tgz" --wildcards 'package/dist/update-managed-service-handoff-current-*.mjs' |
  grep -c "retained a lossy copy")
INV_A=$(tar -xzOf "$WORK/cand-a.tgz" package/dist/postinstall-inventory.json 2>/dev/null | head -c 1)
note "candidate A fix markers in shipped dist: $FIX_A"
note "candidate B fix markers in shipped dist: $FIX_B"
note "candidate A dist inventory present: ${INV_A:+yes}"

say "install published stable driver $STABLE"
npm install -g "openclaw@$STABLE" --no-audit --no-fund 2>&1 | tail -3
OPENCLAW="$HOME/.npm-global/bin/openclaw"
note "published driver: $("$OPENCLAW" --version 2>&1)"
BASE_MARKERS=$(grep -c "retained a lossy copy" \
  "$HOME"/.npm-global/lib/node_modules/openclaw/dist/update-managed-service-handoff-current-*.mjs 2>/dev/null | head -1)
note "published driver fix markers in shipped dist: ${BASE_MARKERS:-0}"

say "start loopback registries for the candidates"
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
  curl -s "http://127.0.0.1:$port/openclaw" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
  const doc = JSON.parse(raw);
  const version = doc["dist-tags"].latest;
  console.log(`registry latest=${version} schemaVersions=${JSON.stringify(doc.versions[version].openclaw?.schemaVersions)}`);
});
' | tee -a "$SUMMARY"
done

say "seed operator state (settings, workspace data)"
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

say "install and start the managed gateway service"
"$OPENCLAW" gateway install --port "$PORT" --token "$TOKEN" --json 2>&1 | tail -4
wait_gateway_running() {
  for _ in $(seq 1 150); do
    "$OPENCLAW" gateway status --json >/tmp/gateway-status.json 2>/dev/null || true
    node -e 'const s=require("/tmp/gateway-status.json");process.exit(s?.service?.runtime?.status==="running"?0:1)' 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
wait_gateway_running && note "gateway service: running" || note "gateway service: NOT running"
systemctl --user show openclaw-gateway.service -p ActiveState -p SubState -p MainPID | tee -a "$SUMMARY"

say "seed a cron data marker through the shipped CLI"
"$OPENCLAW" cron add --name proof-data --every 1d --agent main --message "proof turn" --json 2>&1 | tail -2
"$OPENCLAW" cron list --json >/tmp/cron-before.json 2>/dev/null || true
node -e '
const jobs = require("/tmp/cron-before.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
console.log(`cron before: ${list.length} job(s) ${list.map((job) => job.name ?? job.displayName ?? job.id).join(",")}`);
' | tee -a "$SUMMARY"

# Scheduled command job: the updater runs as a Gateway child, like a real
# automation-triggered update. The preload only arms inside the managed handoff
# updater, so every other process in the tree is untouched.
run_scheduled_update() {
  local label="$1" registry="$2"
  local out="/tmp/update-$label.json"
  local script="/tmp/run-update-$label.sh"
  cat >"$script" <<SH
#!/bin/bash
export NODE_OPTIONS="--import file://$GITHUB_WORKSPACE/scripts/inject-utf8.mjs"
export PROOF_INJECT_LOG="/tmp/inject-$label.log"
export NPM_CONFIG_REGISTRY="http://127.0.0.1:$registry"
export OPENCLAW_UPDATE_PACKAGE_SPEC=openclaw
"$OPENCLAW" update --yes --json --timeout 1200 >"$out" 2>"$out.err"
echo \$? >"$out.rc"
SH
  chmod +x "$script"
  : >"/tmp/inject-$label.log"
  rm -f "$out" "$out.err" "$out.rc"
  local job_id
  job_id=$("$OPENCLAW" cron add --name "proof-update-$label" --cron "0 0 1 1 *" \
    --command "bash $script" --json 2>/dev/null |
    node -e 'let raw="";process.stdin.on("data",(d)=>raw+=d).on("end",()=>{try{const j=JSON.parse(raw);console.log(j.id??j.job?.id??"")}catch{console.log("")}})')
  note "$label cron job id: ${job_id:-none}"
  local before_dir
  before_dir=$(ls -dt /tmp/openclaw-update-run-handoff-* 2>/dev/null | head -1)
  "$OPENCLAW" cron run "$job_id" --json 2>&1 | tail -3
  # Wait for the handoff helper to settle; the Gateway restarts during activation.
  local handoff=""
  for _ in $(seq 1 120); do
    sleep 5
    handoff=$(ls -dt /tmp/openclaw-update-run-handoff-* 2>/dev/null | head -1)
    if [ -n "$handoff" ] && [ "$handoff" != "$before_dir" ] &&
      grep -q "helper completed" "$handoff/handoff.log" 2>/dev/null; then
      break
    fi
  done
  note "$label handoff dir: ${handoff:-none}"
  if [ -n "$handoff" ] && [ -f "$handoff/handoff.log" ]; then
    WARN_LINES=$(grep -c 'invalid UTF-8' "$handoff/handoff.log" 2>/dev/null | head -1)
    note "$label handoff invalid-UTF-8 lines: ${WARN_LINES:-0}"
    grep 'invalid UTF-8' "$handoff/handoff.log" 2>/dev/null | tee -a "$SUMMARY"
    grep -E 'ownership transferred|starting managed update command|update command pid|update command exited|helper completed' \
      "$handoff/handoff.log" 2>/dev/null | tee -a "$SUMMARY"
  fi
  echo "--- $label injector log ---"
  cat "/tmp/inject-$label.log" 2>/dev/null | tee -a "$SUMMARY"
  echo "--- $label update output ---"
  cat "$out" 2>/dev/null | tail -20
  echo "--- $label rc: $(cat "$out.rc" 2>/dev/null || echo missing) ---"
  wait_gateway_running && note "$label gateway service: running" || note "$label gateway service: NOT running"
}

say "RUN A: published stable $STABLE -> candidate $CAND_A (driver without the fix)"
run_scheduled_update "runA" 48771
A_INSTALLED=$("$OPENCLAW" --version 2>&1)
note "runA installed: $A_INSTALLED"
note "runA settings sha256: $(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"
"$OPENCLAW" cron list --json >/tmp/cron-after-a.json 2>/dev/null || true

say "RUN B: installed candidate $CAND_A (driver with the fix) -> $CAND_B"
run_scheduled_update "runB" 48772
B_INSTALLED=$("$OPENCLAW" --version 2>&1)
note "runB installed: $B_INSTALLED"
note "runB settings sha256: $(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"

say "verify operator data survived"
node -e '
const jobs = require("/tmp/cron-after-a.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
const names = list.map((job) => job.name ?? job.displayName ?? job.id);
console.log(`cron after: ${list.length} job(s) ${names.join(",")}`);
console.log(`proof-data=${names.includes("proof-data") ? "present" : "MISSING"}`);
' | tee -a "$SUMMARY"
node -e '
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.env.HOME + "/.openclaw/openclaw.json", "utf8"));
console.log(`config gateway.port=${config.gateway?.port} logging.level=${config.logging?.level} workspace=${config.agents?.defaults?.workspace}`);
' | tee -a "$SUMMARY"
note "workspace marker: $(cat "$HOME/.openclaw/workspace/PROOF_MARKER.txt" 2>/dev/null)"
"$OPENCLAW" gateway status --json >/tmp/gateway-status-after.json 2>/dev/null || true
node -e '
const s = require("/tmp/gateway-status-after.json");
console.log(`service after=${s?.service?.runtime?.status} version=${s?.service?.runtime?.version ?? s?.rpc?.version ?? "n/a"} pid=${s?.service?.runtime?.pid ?? "n/a"}`);
' | tee -a "$SUMMARY"
ls -lt "$HOME"/.openclaw/update-reports 2>/dev/null | head -4 | tee -a "$SUMMARY"

say "verdict"
A_OK=no
case "$A_INSTALLED" in *"$CAND_A"*) A_OK=yes ;; esac
B_OK=no
case "$B_INSTALLED" in *"$CAND_B"*) B_OK=yes ;; esac
WARN_TOTAL=$(grep -h -c 'invalid UTF-8' /tmp/openclaw-update-run-handoff-*/handoff.log 2>/dev/null | awk '{sum += $1} END {print sum + 0}')
note "verdict inputs: runA=$A_OK runB=$B_OK handoffWarnings=$WARN_TOTAL"
for log in /tmp/openclaw-update-run-handoff-*/handoff.log; do
  grep -H 'invalid UTF-8' "$log" 2>/dev/null
done | tee -a "$SUMMARY"
if [ "$A_OK" = yes ] && [ "$B_OK" = yes ] && [ "$WARN_TOTAL" -ge 1 ]; then
  note "VERDICT=PASS"
else
  note "VERDICT=FAIL"
  exit 1
fi
