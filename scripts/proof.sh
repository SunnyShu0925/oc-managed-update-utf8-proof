#!/usr/bin/env bash
# Managed-service update proof for PR #186033 (strict UTF-8 decoding of the
# managed update handoff output), on a GitHub-hosted Ubuntu VM with real systemd.
#
#   Run A: published 2026.10.8 driver (no fix)  -> published 2026.10.10-beta.3
#   Run B: reviewed build driver (has the fix)  -> published 2026.10.10-beta.4
#
# Both updates are started from a cron command job, so the updater runs inside the
# Gateway process tree exactly like a scheduled update and uses the shipped
# managed-service handoff. A preload in the Gateway environment adds one raw 0xFF
# byte to the handoff updater's stdout, so the handoff decoder is the only thing
# that differs between the two drivers.
set -uo pipefail

STABLE="${STABLE_VERSION:-2026.10.8}"
BASE_TARGET="${BASE_TARGET_VERSION:-2026.10.10-beta.3}"
FIX_TARGET="${FIX_TARGET_VERSION:-2026.10.10-beta.4}"
CAND="${CAND_VERSION:-2026.10.9}"
ASSET_BASE="${ASSET_BASE:-https://github.com/SunnyShu0925/oc-managed-update-utf8-proof/releases/download/v1}"
PORT=18833
TOKEN=proof-token-186033
WORK=/tmp/proof186033
SUMMARY=/tmp/proof-summary.txt
INJECT_LOG=/tmp/inject-gateway.log
mkdir -p "$WORK"
: >"$SUMMARY"
: >"$INJECT_LOG"

say() { echo; echo "=== $* ==="; }
note() { echo "$*" | tee -a "$SUMMARY"; }

say "environment"
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

say "fetch the reviewed driver build"
curl -fsSL -o "$WORK/cand.tgz" "$ASSET_BASE/openclaw-$CAND.tgz"
sha256sum "$WORK/cand.tgz" | tee -a "$SUMMARY"
tar -xzOf "$WORK/cand.tgz" package/package.json >"$WORK/cand-manifest.json"
note "reviewed driver package version: $(node -p "require('$WORK/cand-manifest.json').version")"
FIX_A=$(tar -xzOf "$WORK/cand.tgz" --wildcards 'package/dist/update-managed-service-handoff-current-*.mjs' |
  grep -c "retained a lossy copy")
INV_A=$(tar -xzOf "$WORK/cand.tgz" package/dist/postinstall-inventory.json 2>/dev/null | head -c 1)
note "reviewed build fix markers in shipped dist: $FIX_A"
note "reviewed build dist inventory present: ${INV_A:+yes}"

say "install published stable driver $STABLE"
npm install -g "openclaw@$STABLE" --no-audit --no-fund 2>&1 | tail -3
OPENCLAW="$HOME/.npm-global/bin/openclaw"
note "published driver: $("$OPENCLAW" --version 2>&1)"
BASE_MARKERS=$(grep -c "retained a lossy copy" \
  "$HOME"/.npm-global/lib/node_modules/openclaw/dist/update-managed-service-handoff-current-*.mjs 2>/dev/null | head -1)
note "published driver fix markers in shipped dist: ${BASE_MARKERS:-0}"

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
wait_gateway_running && note "gateway service: running" || note "gateway service: NOT running"
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
  journalctl --user -u openclaw-gateway --no-pager -n 40 2>&1 | tail -40 | tee -a "$SUMMARY"
  exit 1
fi
note "gateway restarted with the preload"
wait_gateway_rpc && note "gateway RPC after restart: ready" || note "gateway RPC after restart: NOT ready"
systemctl --user show openclaw-gateway.service -p ActiveState -p MainPID | tee -a "$SUMMARY"

say "seed a cron data marker through the shipped CLI"
"$OPENCLAW" cron add --name proof-data --every 1d --agent main --message "proof turn" --json 2>&1 | tail -3
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
  local label="$1" target="$2" trigger="${3:-$OPENCLAW}"
  local out="/tmp/update-$label.json"
  local script="/tmp/run-update-$label.sh"
  cat >"$script" <<SH
#!/bin/bash
echo "[\$(date -u +%FT%TZ)] $label scheduled update start -> $target" >>"$INJECT_LOG"
"$OPENCLAW" update --yes --json --tag "$target" --timeout 1200 >"$out" 2>"$out.err"
echo \$? >"$out.rc"
SH
  chmod +x "$script"
  rm -f "$out" "$out.err" "$out.rc"
  local job_id=""
  for _ in $(seq 1 30); do
    job_id=$("$trigger" cron add --name "proof-update-$label" --cron "0 0 1 1 *" \
      --command "bash $script" --json 2>/tmp/cron-add-$label.err |
      node -e 'let raw="";process.stdin.on("data",(d)=>raw+=d).on("end",()=>{try{const j=JSON.parse(raw);console.log(j.id??j.job?.id??"")}catch{console.log("")}})')
    [ -n "$job_id" ] && break
    sleep 5
  done
  note "$label cron job id: ${job_id:-none}"
  if [ -z "$job_id" ]; then
    tail -5 "/tmp/cron-add-$label.err" | tee -a "$SUMMARY"
    return 1
  fi
  local before_dir before_report
  before_dir=$(ls -dt /tmp/openclaw-update-run-handoff-* 2>/dev/null | head -1)
  before_report=$(ls -t "$HOME"/.openclaw/update-reports/*.md 2>/dev/null | head -1)
  "$trigger" cron run "$job_id" --json 2>&1 | tail -3
  local handoff=""
  for _ in $(seq 1 100); do
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
    grep -E 'ownership transferred|starting managed update command|update command exited|helper completed' \
      "$handoff/handoff.log" 2>/dev/null | tail -8 | tee -a "$SUMMARY"
    cp "$handoff/handoff.log" "/tmp/handoff-$label.log" 2>/dev/null || true
  fi
  echo "--- $label injector log ---"
  cat "$INJECT_LOG" 2>/dev/null | tail -8 | tee -a "$SUMMARY"
  echo "--- $label rc: $(cat "$out.rc" 2>/dev/null || echo missing) ---"
  local report
  report=$(ls -t "$HOME"/.openclaw/update-reports/*.md 2>/dev/null | head -1)
  if [ -n "$report" ] && [ "$report" != "$before_report" ]; then
    echo "--- $label update report ---"
    head -12 "$report" | tee -a "$SUMMARY"
  fi
  wait_gateway_running && note "$label gateway service: running" || note "$label gateway service: NOT running"
}

say "RUN A: published $STABLE driver (no fix) -> published $BASE_TARGET"
run_scheduled_update "runA" "$BASE_TARGET"
A_INSTALLED=$("$OPENCLAW" --version 2>&1)
note "runA installed: $A_INSTALLED"
note "runA settings sha256: $(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"
"$OPENCLAW" cron list --json >/tmp/cron-after-a.json 2>/dev/null || true

say "install the reviewed driver build ($CAND)"
# Keep the already-running Gateway so the update driver on disk can be the reviewed
# build without restarting production code mid-proof. The saved published CLI is
# used only for Gateway RPC while the reviewed build performs the update.
npm install -g --prefix /tmp/published-cli "openclaw@$BASE_TARGET" --no-audit --no-fund 2>&1 | tail -2
PUBLISHED_CLI=/tmp/published-cli/bin/openclaw
note "saved published CLI: $("$PUBLISHED_CLI" --version 2>&1)"
npm install -g "$WORK/cand.tgz" --no-audit --no-fund 2>&1 | tail -3
note "reviewed driver installed: $("$OPENCLAW" --version 2>&1)"
if systemctl --user is-active openclaw-gateway >/dev/null 2>&1; then
  note "gateway service still running while the reviewed CLI is installed"
else
  note "gateway service stopped after the driver swap"
  journalctl --user -u openclaw-gateway --no-pager -n 40 2>&1 | tail -40 | tee -a "$SUMMARY"
  exit 1
fi

say "RUN B: reviewed driver (with the fix) -> published $FIX_TARGET"
run_scheduled_update "runB" "$FIX_TARGET" "$PUBLISHED_CLI"
B_INSTALLED=$("$OPENCLAW" --version 2>&1)
note "runB installed: $B_INSTALLED"

say "verify operator data survived"
VERIFY_CLI="${PUBLISHED_CLI:-$OPENCLAW}"
"$VERIFY_CLI" cron list --json >/tmp/cron-after.json 2>/dev/null || true
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
"$VERIFY_CLI" gateway status --json >/tmp/gateway-status-after.json 2>/dev/null || true
node -e '
const s = require("/tmp/gateway-status-after.json");
console.log(`service after=${s?.service?.runtime?.status} version=${s?.service?.runtime?.version ?? s?.rpc?.version ?? "n/a"} pid=${s?.service?.runtime?.pid ?? "n/a"}`);
' | tee -a "$SUMMARY"

say "verdict"
A_OK=no
case "$A_INSTALLED" in *"$BASE_TARGET"*) A_OK=yes ;; esac
B_OK=no
case "$B_INSTALLED" in *"$FIX_TARGET"*) B_OK=yes ;; esac
WARN_TOTAL=$(grep -h -c 'invalid UTF-8' /tmp/openclaw-update-run-handoff-*/handoff.log 2>/dev/null | awk '{sum += $1} END {print sum + 0}')
SETTINGS_OK=no
[ "$(sha256sum "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)" = "$SETTINGS_SHA" ] && SETTINGS_OK=yes
note "verdict inputs: runA=$A_OK runB=$B_OK handoffWarnings=$WARN_TOTAL settingsIntact=$SETTINGS_OK"
for log in /tmp/openclaw-update-run-handoff-*/handoff.log; do
  grep -H 'invalid UTF-8' "$log" 2>/dev/null
done | tee -a "$SUMMARY"
if [ "$A_OK" = yes ] && [ "$B_OK" = yes ] && [ "$WARN_TOTAL" -ge 1 ] && [ "$SETTINGS_OK" = yes ]; then
  note "VERDICT=PASS"
else
  note "VERDICT=FAIL"
  exit 1
fi
