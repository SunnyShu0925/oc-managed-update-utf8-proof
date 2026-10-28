#!/usr/bin/env bash
# Managed-service update proof for PR #186033 (strict UTF-8 decoding of the
# managed update handoff output) on a GitHub-hosted Ubuntu VM with real systemd.
#
# One scenario per run (SCENARIO env):
#   baseline: published 2026.10.8 driver (no fix)  -> published 2026.10.10-beta.3
#   fix:      reviewed build driver (has the fix)  -> published 2026.10.10-beta.4
#
# The update is started from a cron command job, so the updater runs inside the
# Gateway process tree exactly like a scheduled update and uses the shipped
# managed-service handoff. A preload in the Gateway environment adds one raw 0xFF
# byte to the handoff updater's stdout, so the handoff decoder is the exercise.
set -uo pipefail

SCENARIO="${SCENARIO:-fix}"
STABLE="${STABLE_VERSION:-2026.10.8}"
BASE_TARGET="${BASE_TARGET_VERSION:-2026.10.10-beta.3}"
FIX_TARGET="${FIX_TARGET_VERSION:-2026.10.10-beta.4}"
CAND="${CAND_VERSION:-2026.10.9}"
ASSET_BASE="${ASSET_BASE:-https://github.com/SunnyShu0925/oc-managed-update-utf8-proof/releases/download/v1}"
PORT="${GATEWAY_PORT:-18833}"
TOKEN=proof-token-186033
WORK=/tmp/proof186033
SUMMARY=/tmp/proof-summary.txt
INJECT_LOG=/tmp/inject-gateway.log
mkdir -p "$WORK"
: >"$SUMMARY"
: >"$INJECT_LOG"

if [ "$SCENARIO" = "baseline" ]; then
  TARGET="$BASE_TARGET"
  DRIVER_LABEL="published $STABLE (no fix)"
  EXPECT_WARN=0
else
  TARGET="$FIX_TARGET"
  DRIVER_LABEL="reviewed build $CAND (has the fix)"
  EXPECT_WARN=1
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
  echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"
  systemctl --user is-system-running || true
  busctl --user list | grep -E "org.freedesktop.systemd1" || echo "systemd1 not on the user bus"
} 2>&1 | tee -a "$SUMMARY"
note "proof harness commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
note "scenario=$SCENARIO driver=$DRIVER_LABEL target=$TARGET"

say "install the driver: $DRIVER_LABEL"
if [ "$SCENARIO" = "fix" ]; then
  curl -fsSL -o "$WORK/cand.tgz" "$ASSET_BASE/openclaw-$CAND.tgz"
  sha256sum "$WORK/cand.tgz" | tee -a "$SUMMARY"
  FIX_MARKERS=$(tar -xzOf "$WORK/cand.tgz" --wildcards 'package/dist/update-managed-service-handoff-current-*.mjs' |
    grep -c "retained a lossy copy")
  INV=$(tar -xzOf "$WORK/cand.tgz" package/dist/postinstall-inventory.json 2>/dev/null | head -c 1)
  note "reviewed build fix markers in shipped dist: $FIX_MARKERS"
  note "reviewed build dist inventory present: ${INV:+yes}"
  npm install -g "$WORK/cand.tgz" --no-audit --no-fund 2>&1 | tail -3
else
  npm install -g "openclaw@$STABLE" --no-audit --no-fund 2>&1 | tail -3
fi
OPENCLAW="$HOME/.npm-global/bin/openclaw"
note "installed driver: $("$OPENCLAW" --version 2>&1)"
DRIVER_MARKERS=$(grep -c "retained a lossy copy" \
  "$HOME"/.npm-global/lib/node_modules/openclaw/dist/update-managed-service-handoff-current-*.mjs 2>/dev/null | head -1)
note "installed driver fix markers in shipped dist: ${DRIVER_MARKERS:-0}"

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
SETTINGS_SHA=$(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)
note "settings sha256: $SETTINGS_SHA"

say "install and start the managed gateway service"
"$OPENCLAW" gateway install --port "$PORT" --token "$TOKEN" --json 2>&1 | tail -4
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

say "seed a cron data marker through the shipped CLI"
"$OPENCLAW" cron add --name proof-data --every 1d --agent main --message "proof turn" --json 2>&1 | tail -3
"$OPENCLAW" cron list --json >/tmp/cron-before.json 2>/dev/null || true
node -e '
const jobs = require("/tmp/cron-before.json");
const list = Array.isArray(jobs) ? jobs : (jobs.jobs ?? []);
console.log(`cron before: ${list.length} job(s) ${list.map((job) => job.name ?? job.displayName ?? job.id).join(",")}`);
' | tee -a "$SUMMARY"

say "RUN: $DRIVER_LABEL -> published $TARGET"
OUT=/tmp/update.json
SCRIPT=/tmp/run-update.sh
cat >"$SCRIPT" <<SH
#!/bin/bash
echo "[\$(date -u +%FT%TZ)] scheduled update start -> $TARGET" >>"$INJECT_LOG"
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
"$OPENCLAW" cron run "$JOB_ID" --json 2>&1 | tail -3
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
  head -12 "$REPORT" | tee -a "$SUMMARY"
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
console.log(`proof-data=${names.includes("proof-data") ? "present" : "MISSING"}`);
' | tee -a "$SUMMARY"
node -e '
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.env.HOME + "/.openclaw/openclaw.json", "utf8"));
console.log(`config gateway.port=${config.gateway?.port} logging.level=${config.logging?.level} workspace=${config.agents?.defaults?.workspace}`);
' | tee -a "$SUMMARY"
note "final settings sha256: $(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"
note "workspace marker: $(cat "$HOME/.openclaw/workspace/PROOF_MARKER.txt" 2>/dev/null)"
"$OPENCLAW" gateway status --json >/tmp/gateway-status-after.json 2>/dev/null || true
node -e '
const s = require("/tmp/gateway-status-after.json");
console.log(`service after=${s?.service?.runtime?.status} version=${s?.service?.runtime?.version ?? s?.rpc?.version ?? "n/a"} pid=${s?.service?.runtime?.pid ?? "n/a"}`);
' | tee -a "$SUMMARY"

say "verdict ($SCENARIO)"
TARGET_OK=no
case "$INSTALLED" in *"$TARGET"*) TARGET_OK=yes ;; esac
SETTINGS_OK=no
[ "$(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)" = "$SETTINGS_SHA" ] && SETTINGS_OK=yes
WARN_OK=no
if [ "$EXPECT_WARN" = "1" ] && [ "${WARN_LINES:-0}" -ge 1 ]; then WARN_OK=yes; fi
if [ "$EXPECT_WARN" = "0" ] && [ "${WARN_LINES:-0}" -eq 0 ]; then WARN_OK=yes; fi
note "verdict inputs: targetInstalled=$TARGET_OK settingsIntact=$SETTINGS_OK warnings=$WARN_LINES expectWarning=$EXPECT_WARN"
if [ "$TARGET_OK" = yes ] && [ "$SETTINGS_OK" = yes ] && [ "$WARN_OK" = yes ]; then
  note "VERDICT=PASS"
else
  note "VERDICT=FAIL"
  exit 1
fi
