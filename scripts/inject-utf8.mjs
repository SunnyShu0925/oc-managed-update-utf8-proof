// NODE_OPTIONS=--import preload for the managed-update proof.
//
// It loads in every Node process of the update tree, but only arms inside the
// updater subprocess the managed handoff helper spawns (OPENCLAW_UPDATE_RUN_HANDOFF=1
// and a handoff.cjs parent). There it appends one extra JSON string field whose
// value starts with a single raw 0xFF byte, so the updater's --json stdout is not
// valid UTF-8 while its lossy copy is still valid JSON. Nothing else changes.
import fs from "node:fs";

const logPath = process.env.PROOF_INJECT_LOG;
function log(line) {
  if (!logPath) return;
  try {
    fs.appendFileSync(logPath, `${line}\n`);
  } catch {}
}

const argv = process.argv.slice(1);
// The updater is the CLI the managed handoff helper spawns directly. Older
// drivers (for example published 2026.10.8) do not set
// OPENCLAW_UPDATE_RUN_HANDOFF, so the parent process identity is the guard.
const inManagedUpdate = argv.includes("update");
let parentCmdline = "";
if (inManagedUpdate) {
  try {
    parentCmdline = fs.readFileSync(`/proc/${process.ppid}/cmdline`, "utf8");
  } catch {}
}

if (inManagedUpdate && parentCmdline.includes("handoff.cjs")) {
  log(`armed pid=${process.pid} ppid=${process.ppid} argv=${JSON.stringify(argv)}`);
  let injected = false;
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = (chunk, encoding, callback) => {
    let nextChunk = chunk;
    let nextEncoding = encoding;
    let nextCallback = callback;
    if (typeof nextEncoding === "function") {
      nextCallback = nextEncoding;
      nextEncoding = undefined;
    }
    try {
      if (!injected) {
        const buffer = Buffer.isBuffer(nextChunk)
          ? nextChunk
          : Buffer.from(
              String(nextChunk),
              typeof nextEncoding === "string" ? nextEncoding : "utf8",
            );
        const match = /"status"\s*:\s*"(?:ok|skipped|error)"/.exec(buffer.toString("latin1"));
        if (match) {
          const at = match.index + match[0].length;
          nextChunk = Buffer.concat([
            buffer.subarray(0, at),
            Buffer.from(',"proofInjectedStdout":"', "latin1"),
            Buffer.from([0xff]),
            Buffer.from('"', "latin1"),
            buffer.subarray(at),
          ]);
          nextEncoding = undefined;
          injected = true;
          log(`injected 0xff into updater stdout pid=${process.pid} offset=${at}`);
        }
      }
    } catch (error) {
      log(`injector error pid=${process.pid}: ${String(error)}`);
    }
    return write(nextChunk, nextEncoding, nextCallback);
  };
} else if (inManagedUpdate) {
  log(`skipped pid=${process.pid} parent=${parentCmdline.replace(/\0/g, " ").slice(0, 120)}`);
}
