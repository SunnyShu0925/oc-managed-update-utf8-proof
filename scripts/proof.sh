#!/usr/bin/env bash
# Managed-service update proof for PR #186033 (strict UTF-8 decoding of the
# managed update handoff output) on a GitHub-hosted Ubuntu VM with real systemd.
#
# Two scenarios, one per job:
#   stable-driver:   published 2026.10.8 -> reviewed candidate package (served by a
#                    loopback registry)   expect: completed upgrade, 0 warnings
#   reviewed-driver: reviewed driver build -> published 2026.10.10-beta.4
#                    expect: completed upgrade, 1 warning from the reviewed decoder
#
# The update is started from a cron command job, so the updater runs inside the
# Gateway process tree and takes the shipped managed-service handoff. A preload
# in the Gateway environment appends one raw 0xFF byte inside the updater's JSON
# stdout, so the handoff decoder is the code under test.
set -uo pipefail

SCENARIO="${SCENARIO:-stable-driver}"
STABLE="${STABLE_VERSION:-2026.10.8}"
CAND="${CAND_VERSION:-2026.10.10-beta.4}"
DRIVER="${DRIVER_VERSION:-2026.10.9}"
PORT="${GATEWAY_PORT:-18833}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/proof-artifacts}"
EXPECT_BUILD_ID="$(head -1 "$ARTIFACT_DIR/reviewed-build-id.txt" 2>/dev/null | tr -d '[:space:]')"
TOKEN=proof-token-186033
WORK=/tmp/proof186033
SUMMARY=/tmp/proof-summary.txt
INJECT_LOG=/tmp/inject-gateway.log
REGISTRY_PORT=48771
mkdir -p "$WORK" "$HOME/.openclaw/workspace"
: >"$SUMMARY"
: >"$INJECT_LOG"

TARGET="$CAND"
if [ "$SCENARIO" = "stable-driver" ]; then
  DRIVER_LABEL="published driver $STABLE (no fix)"
  DRIVER_MODE=npm
  USE_REGISTRY=1
  EXPECT_WARN=0
  EXPECT_TARGET_BUILD="$EXPECT_BUILD_ID"
else
  DRIVER_LABEL="reviewed driver $DRIVER (has the fix)"
  DRIVER_MODE=tarball
  USE_REGISTRY=1
  EXPECT_WARN=1
  EXPECT_TARGET_BUILD="$EXPECT_BUILD_ID"
fi

say() { echo; echo "=== $* ==="; }
note() { echo "$*" | tee -a "$SUMMARY"; }

say "environment ($SCENARIO)"
{
  uname -a
  systemctl --version | head -1
  node --version
  npm --version
  echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
  systemctl --user is-system-running || true
} 2>&1 | tee -a "$SUMMARY"
note "proof harness commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
note "scenario=$SCENARIO driver=$DRIVER_LABEL target=$TARGET"
note "reviewed build id: ${EXPECT_BUILD_ID:-unknown}"
ls -l "$ARTIFACT_DIR" | tee -a "$SUMMARY"

CAND_TARBALL="$ARTIFACT_DIR/openclaw-$CAND.tgz"
DRIVER_TARBALL="$ARTIFACT_DIR/openclaw-$DRIVER.tgz"

say "inspect the reviewed candidate package"
sha256sum "$CAND_TARBALL" | tee -a "$SUMMARY"
CAND_FIX_MARKERS=$(tar -xzOf "$CAND_TARBALL" --wildcards 'package/dist/update-managed-service-handoff-current-*.mjs' |
  grep -c "retained a lossy copy")
note "candidate fix markers in shipped dist: $CAND_FIX_MARKERS"
CAND_INVENTORY=$(tar -xzOf "$CAND_TARBALL" package/dist/postinstall-inventory.json 2>/dev/null | head -c 1)
note "candidate dist inventory present: ${CAND_INVENTORY:+yes}"
tar -xzf "$CAND_TARBALL" -C "$WORK" && mv "$WORK/package" "$WORK/cand-root"
CAND_VERSION_ACTUAL=$(node -e 'console.log(require(process.argv[1]).version)' "$WORK/cand-root/package.json")
note "candidate package version: $CAND_VERSION_ACTUAL"

say "candidate staged install probe (npm install + shipped entrypoint)"
rm -rf "$WORK/stage" && mkdir -p "$WORK/stage"
npm install --prefix "$WORK/stage" --no-audit --no-fund "$CAND_TARBALL" >/dev/null 2>&1
note "staged install rc=$?"
( cd "$WORK/stage/node_modules/openclaw" &&
  node dist/index.js gateway install --update-executor check --json </dev/null ) \
  >"$WORK/cand-probe.json" 2>"$WORK/cand-probe.err"
note "candidate probe (clean env) rc=$?"
head -c 300 "$WORK/cand-probe.json" | tee -a "$SUMMARY"
echo
( cd "$WORK/stage/node_modules/openclaw" &&
  NODE_OPTIONS="--import file://$GITHUB_WORKSPACE/scripts/inject-utf8.mjs" PROOF_INJECT_LOG="$INJECT_LOG" \
  node dist/index.js gateway install --update-executor check --json </dev/null ) \
  >"$WORK/cand-probe-preload.json" 2>"$WORK/cand-probe-preload.err"
note "candidate probe (proof preload env) rc=$?"
head -c 300 "$WORK/cand-probe-preload.json" | tee -a "$SUMMARY"
echo

if [ "$USE_REGISTRY" = "1" ]; then
  say "start the loopback registry that serves the reviewed candidate"
  tar -xzOf "$CAND_TARBALL" package/package.json >"$WORK/candidate-manifest.json"
  PROOF_REGISTRY_PORT="$REGISTRY_PORT" PROOF_TARBALL="$CAND_TARBALL" \
  PROOF_CANDIDATE_VERSION="$CAND" PROOF_BASE_VERSION="$STABLE" \
  PROOF_CANDIDATE_MANIFEST="$WORK/candidate-manifest.json" PROOF_REGISTRY_LOG=/tmp/registry.log \
    node scripts/registry-proxy.mjs >/tmp/registry.out 2>&1 &
  REGISTRY_PID=$!
  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "http://127.0.0.1:$REGISTRY_PORT/openclaw" && break
    sleep 1
  done
  curl -s "http://127.0.0.1:$REGISTRY_PORT/openclaw" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
  const doc = JSON.parse(raw);
  const version = doc["dist-tags"].latest;
  console.log(`registry latest=${version} tarball=${doc.versions[version].dist.tarball}`);
});
' | tee -a "$SUMMARY"
  tail -3 /tmp/registry.log | tee -a "$SUMMARY"
  note "registry pid=$REGISTRY_PID"
fi

say "install the driver: $DRIVER_LABEL"
if [ "$DRIVER_MODE" = "npm" ]; then
  npm install -g "openclaw@$STABLE" --no-audit --no-fund 2>&1 | tail -3 | tee -a "$SUMMARY"
else
  sha256sum "$DRIVER_TARBALL" | tee -a "$SUMMARY"
  DRIVER_FIX_MARKERS=$(tar -xzOf "$DRIVER_TARBALL" --wildcards 'package/dist/update-managed-service-handoff-current-*.mjs' |
    grep -c "retained a lossy copy")
  note "driver fix markers in shipped dist: $DRIVER_FIX_MARKERS"
  npm install -g "$DRIVER_TARBALL" --no-audit --no-fund 2>&1 | tail -3 | tee -a "$SUMMARY"
fi
OPENCLAW="$HOME/.npm-global/bin/openclaw"
note "installed driver: $("$OPENCLAW" --version 2>&1)"

say "seed operator state (settings, workspace data)"
cat >"$HOME/.openclaw/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "bind": "loopback", "port": $PORT, "auth": { "mode": "token", "token": "$TOKEN" } },
  "agents": { "defaults": { "workspace": "$HOME/.openclaw/workspace" }, "entries": { "main": {} } },
  "logging": { "level": "info" }
}
JSON
chmod 600 "$HOME/.openclaw/openclaw.json"
echo "proof-data-marker-186033" >"$HOME/.openclaw/workspace/PROOF_MARKER.txt"
SETTINGS_SHA=$(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)
note "settings sha256: $SETTINGS_SHA"

say "install and start the managed gateway service"
"$OPENCLAW" gateway install --port "$PORT" --token "$TOKEN" --json 2>&1 | tail -4 | tee -a "$SUMMARY"
wait_gateway_running() {
  for _ in $(seq 1 90); do
    "$OPENCLAW" gateway status --json >/tmp/gateway-status.json 2>/dev/null || true
    node -e 'const s=require("/tmp/gateway-status.json");process.exit(s?.service?.runtime?.status==="running"?0:1)' 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
wait_gateway_rpc() {
  for _ in $(seq 1 60); do
    "$OPENCLAW" cron list --json >/tmp/cron-probe.json 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
if ! wait_gateway_running; then
  note "gateway service: NOT running"
  journalctl --user -u openclaw-gateway --no-pager -n 60 2>&1 | tail -60 | tee -a "$SUMMARY"
  exit 1
fi
note "gateway service: running"
wait_gateway_rpc && note "gateway RPC: ready" || note "gateway RPC: NOT ready"
systemctl --user show openclaw-gateway.service -p ActiveState -p SubState -p MainPID | tee -a "$SUMMARY"

say "attach the proof preload to the Gateway service environment"
mkdir -p "$HOME/.config/systemd/user/openclaw-gateway.service.d"
cat >"$HOME/.config/systemd/user/openclaw-gateway.service.d/proof-inject.conf" <<CONF
[Service]
Environment="NODE_OPTIONS=--import file://$GITHUB_WORKSPACE/scripts/inject-utf8.mjs"
Environment="PROOF_INJECT_LOG=$INJECT_LOG"
CONF
systemctl --user daemon-reload
systemctl --user show openclaw-gateway.service -p Environment | tr ' ' '\n' | grep -E "NODE_OPTIONS|PROOF_INJECT_LOG" | tee -a "$SUMMARY"
systemctl --user restart openclaw-gateway
sleep 3
if ! wait_gateway_running; then
  note "gateway restart: NOT running"
  journalctl --user -u openclaw-gateway --no-pager -n 60 2>&1 | tail -60 | tee -a "$SUMMARY"
  exit 1
fi
note "gateway restarted with the preload"
wait_gateway_rpc && note "gateway RPC after restart: ready" || note "gateway RPC after restart: NOT ready"

say "seed operator data through the shipped CLI"
"$OPENCLAW" cron add --name proof-data --cron "0 0 1 1 *" --command "echo proof-data" --json 2>&1 | tail -3 | tee -a "$SUMMARY"
"$OPENCLAW" cron list --json >/tmp/cron-before.json 2>/dev/null || true
node -e '
const jobs = require("/tmp/cron-before.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
const names = list.map((job) => job.name ?? job.displayName ?? job.id);
console.log(`cron before: ${list.length} job(s) ${names.join(",")}`);
console.log(`proof-data seeded=${names.includes("proof-data") ? "yes" : "no"}`);
' | tee -a "$SUMMARY"

say "RUN: $DRIVER_LABEL -> $TARGET"
OUT=/tmp/update.json
SCRIPT=/tmp/run-update.sh
REGISTRY_ENV=""
if [ "$USE_REGISTRY" = "1" ]; then
  REGISTRY_ENV="export NPM_CONFIG_REGISTRY=\"http://127.0.0.1:$REGISTRY_PORT\"
export OPENCLAW_UPDATE_PACKAGE_SPEC=openclaw"
fi
cat >"$SCRIPT" <<SH
#!/bin/bash
echo "[\$(date -u +%FT%TZ)] scheduled update start -> $TARGET" >>"$INJECT_LOG"
$REGISTRY_ENV
"$OPENCLAW" update --yes --json --tag "$TARGET" --timeout 1200 >"$OUT" 2>"$OUT.err"
echo \$? >"$OUT.rc"
SH
chmod +x "$SCRIPT"
rm -f "$OUT" "$OUT.err" "$OUT.rc"
JOB_ID=""
for _ in $(seq 1 30); do
  JOB_ID=$("$OPENCLAW" cron add --name "proof-update" --cron "0 0 1 1 *" --command "bash $SCRIPT" --json 2>/tmp/cron-add.err |
    node -e 'let raw="";process.stdin.on("data",(d)=>raw+=d).on("end",()=>{try{const j=JSON.parse(raw);console.log(j.id??j.job?.id??"")}catch{console.log("")}})')
  [ -n "$JOB_ID" ] && break
  sleep 5
done
note "cron job id: ${JOB_ID:-none}"
if [ -z "$JOB_ID" ]; then
  tail -5 /tmp/cron-add.err | tee -a "$SUMMARY"
  exit 1
fi
BEFORE_DIR=$(ls -dt /tmp/openclaw-update-run-handoff-* 2>/dev/null | head -1)
BEFORE_REPORT=$(ls -t "$HOME"/.openclaw/update-reports/*.md 2>/dev/null | head -1)
"$OPENCLAW" cron run "$JOB_ID" --json 2>&1 | tail -3 | tee -a "$SUMMARY"
HANDOFF=""
for _ in $(seq 1 100); do
  sleep 5
  HANDOFF=$(ls -dt /tmp/openclaw-update-run-handoff-* 2>/dev/null | head -1)
  if [ -n "$HANDOFF" ] && [ "$HANDOFF" != "$BEFORE_DIR" ] &&
    grep -q "helper completed" "$HANDOFF/handoff.log" 2>/dev/null; then
    break
  fi
done
note "handoff dir: ${HANDOFF:-none}"
WARN_LINES=0
if [ -n "$HANDOFF" ] && [ -f "$HANDOFF/handoff.log" ]; then
  WARN_LINES=$(grep -c 'invalid UTF-8' "$HANDOFF/handoff.log" 2>/dev/null | head -1)
  note "handoff invalid-UTF-8 lines: ${WARN_LINES:-0}"
  grep 'invalid UTF-8' "$HANDOFF/handoff.log" 2>/dev/null | tee -a "$SUMMARY"
  grep -E 'ownership transferred|starting managed update command|update command exited|helper completed' \
    "$HANDOFF/handoff.log" 2>/dev/null | tail -8 | tee -a "$SUMMARY"
  cp "$HANDOFF/handoff.log" /tmp/handoff.log 2>/dev/null || true
else
  note "handoff log: NOT FOUND"
fi
echo "--- injector log (tail) ---"
tail -8 "$INJECT_LOG" 2>/dev/null | tee -a "$SUMMARY"
echo "--- update rc: $(cat "$OUT.rc" 2>/dev/null || echo missing) ---"
REPORT=$(ls -t "$HOME"/.openclaw/update-reports/*.md 2>/dev/null | head -1)
if [ -n "$REPORT" ] && [ "$REPORT" != "$BEFORE_REPORT" ]; then
  echo "--- update report ---"
  head -20 "$REPORT" | tee -a "$SUMMARY"
fi
wait_gateway_running && note "gateway service: running" || note "gateway service: NOT running"

say "verify operator data survived"
INSTALLED=$("$OPENCLAW" --version 2>&1)
note "installed after update: $INSTALLED"
"$OPENCLAW" cron list --json >/tmp/cron-after.json 2>/dev/null || true
node -e '
const jobs = require("/tmp/cron-after.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
const names = list.map((job) => job.name ?? job.displayName ?? job.id);
console.log(`cron after: ${list.length} job(s) ${names.join(",")}`);
console.log(`proof-data survived=${names.includes("proof-data") ? "yes" : "no"}`);
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

say "verdict ($SCENARIO)"
TARGET_OK=no
case "$INSTALLED" in *"$TARGET"*) TARGET_OK=yes ;; esac
BUILD_OK=n/a
if [ -n "$EXPECT_TARGET_BUILD" ]; then
  BUILD_OK=no
  case "$INSTALLED" in *"($EXPECT_TARGET_BUILD)"*) BUILD_OK=yes ;; esac
fi
SETTINGS_OK=no
[ "$(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)" = "$SETTINGS_SHA" ] && SETTINGS_OK=yes
DATA_OK=no
[ "$(cat "$HOME/.openclaw/workspace/PROOF_MARKER.txt" 2>/dev/null)" = "proof-data-marker-186033" ] && DATA_OK=yes
WARN_OK=no
if [ "$EXPECT_WARN" = "1" ] && [ "${WARN_LINES:-0}" -ge 1 ]; then WARN_OK=yes; fi
if [ "$EXPECT_WARN" = "0" ] && [ "${WARN_LINES:-0}" -eq 0 ]; then WARN_OK=yes; fi
note "verdict inputs: targetInstalled=$TARGET_OK targetBuildMatch=$BUILD_OK settingsIntact=$SETTINGS_OK dataIntact=$DATA_OK warnings=$WARN_LINES expectWarning=$EXPECT_WARN"
if [ "$TARGET_OK" = yes ] && [ "$BUILD_OK" != no ] && [ "$SETTINGS_OK" = yes ] && [ "$DATA_OK" = yes ] && [ "$WARN_OK" = yes ]; then
  note "VERDICT=PASS"
else
  note "VERDICT=FAIL"
  exit 1
fi
