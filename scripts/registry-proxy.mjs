// Loopback npm registry used by the container proof so the shipped updater can
// resolve the reviewed candidate build. Unknown paths are proxied verbatim to
// the public registry (through the environment proxy).
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import { Readable } from "node:stream";

const PORT = Number(process.env.PROOF_REGISTRY_PORT || 48731);
const UPSTREAM = "https://registry.npmjs.org";
const TARBALL_PATH = process.env.PROOF_TARBALL;
const CANDIDATE_VERSION = process.env.PROOF_CANDIDATE_VERSION || "2026.10.9";
const BASE_VERSION = process.env.PROOF_BASE_VERSION || "2026.10.8";
const CANDIDATE_MANIFEST_PATH = process.env.PROOF_CANDIDATE_MANIFEST;
const LOG = process.env.PROOF_REGISTRY_LOG || "/dev/stderr";

const tarballBytes = fs.readFileSync(TARBALL_PATH);
const tarballName = `openclaw-${CANDIDATE_VERSION}.tgz`;
const integrity = `sha512-${crypto.createHash("sha512").update(tarballBytes).digest("base64")}`;
const shasum = crypto.createHash("sha1").update(tarballBytes).digest("hex");
function log(line) {
  fs.appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`);
}

const packumentCache = new Map();

async function fetchUpstream(pathname) {
  const response = await fetch(`${UPSTREAM}${pathname}`, {
    headers: { accept: "application/json" },
  });
  if (!response.ok) {
    log(`upstream ${pathname} -> ${response.status}`);
    return { status: response.status, body: Buffer.from(await response.text()) };
  }
  const body = Buffer.from(await response.arrayBuffer());
  return { status: 200, body };
}

async function candidatePackument() {
  const cached = packumentCache.get("openclaw");
  if (cached) return cached;
  const upstream = await fetchUpstream("/openclaw");
  if (upstream.status !== 200) throw new Error(`upstream packument ${upstream.status}`);
  const doc = JSON.parse(upstream.body.toString("utf8"));
  const base = doc.versions?.[BASE_VERSION];
  if (!base) throw new Error(`upstream packument is missing ${BASE_VERSION}`);
  const manifest = CANDIDATE_MANIFEST_PATH
    ? JSON.parse(fs.readFileSync(CANDIDATE_MANIFEST_PATH, "utf8"))
    : {};
  const entry = {
    ...base,
    ...Object.fromEntries(
      [
        "name",
        "dependencies",
        "optionalDependencies",
        "peerDependencies",
        "engines",
        "bin",
        "os",
        "cpu",
        "openclaw",
      ]
        .filter((key) => manifest[key] !== undefined)
        .map((key) => [key, manifest[key]]),
    ),
    version: CANDIDATE_VERSION,
    dist: {
      ...base.dist,
      tarball: `http://127.0.0.1:${PORT}/openclaw/-/${tarballName}`,
      shasum,
      integrity,
      fileCount: undefined,
      unpackedSize: undefined,
    },
  };
  delete entry.dist.fileCount;
  delete entry.dist.unpackedSize;
  doc.versions[CANDIDATE_VERSION] = entry;
  doc["dist-tags"] = { ...doc["dist-tags"], latest: CANDIDATE_VERSION };
  const body = Buffer.from(JSON.stringify(doc));
  packumentCache.set("openclaw", { status: 200, body });
  log(`serving openclaw packument with latest=${CANDIDATE_VERSION}`);
  return { status: 200, body };
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${PORT}`);
  try {
    if (url.pathname === `/openclaw/-/${tarballName}`) {
      log(`tarball ${tarballName} (${tarballBytes.length} bytes)`);
      response.writeHead(200, {
        "content-type": "application/octet-stream",
        "content-length": String(tarballBytes.length),
      });
      response.end(tarballBytes);
      return;
    }
    if (url.pathname === "/openclaw" || url.pathname === "/openclaw/") {
      const { status, body } = await candidatePackument();
      response.writeHead(status, { "content-type": "application/json" });
      response.end(body);
      return;
    }
    const responseKey = `${url.pathname}${url.search}`;
    const cached = packumentCache.get(responseKey);
    if (cached) {
      response.writeHead(cached.status, { "content-type": "application/json" });
      response.end(cached.body);
      return;
    }
    const upstreamResponse = await fetch(`${UPSTREAM}${url.pathname}${url.search}`, {
      headers: { accept: request.headers.accept ?? "*/*" },
    });
    log(`proxy ${url.pathname} -> ${upstreamResponse.status}`);
    response.writeHead(upstreamResponse.status, {
      "content-type": upstreamResponse.headers.get("content-type") ?? "application/json",
    });
    if (upstreamResponse.body) {
      await new Promise((resolve, reject) => {
        Readable.fromWeb(upstreamResponse.body).pipe(response).on("finish", resolve).on("error", reject);
      });
    } else {
      response.end();
    }
  } catch (error) {
    log(`error ${request.url}: ${error instanceof Error ? error.message : String(error)}`);
    if (!response.headersSent) response.writeHead(502, { "content-type": "text/plain" });
    response.end("registry proxy error");
  }
});

server.listen(PORT, "127.0.0.1", () => {
  log(`listening on 127.0.0.1:${PORT} candidate=${CANDIDATE_VERSION} integrity=${integrity}`);
});
