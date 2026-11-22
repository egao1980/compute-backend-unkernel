// compute-backend-unkernel host: one unkernel kernel per process, newline
// JSON-RPC 2.0 on stdio (rpc-backend-stdio on the Lisp side).
//
//   node unkernel-host.mjs --home HOME
//
// unkernel is imported from HOME/node_modules by absolute path (installed by
// scripts/setup.sh with `npm ci --ignore-scripts` from this directory's
// package.json + package-lock.json, pinned exactly). Methods, params and
// results: src/host.lisp. Rules (cl-stack docs/capabilities/confinement.md
// § R4h-4): createKernel is never given `commands`; every mount but the
// read-write ones has readOnly: true; the net backend is directBackend() with
// hostLoopback off, only for "network": "direct"; forwards listen on
// 127.0.0.1 only; the distro's SHA-256 is checked before boot; the guest disk
// is opened as a snapshot.
//
// The Lisp side owns policy and deadlines (it kills this process on a
// wall-clock). This host still enforces the rules above itself, whatever a
// request says: it is safe for any client on its stdin. stdout carries only
// JSON-RPC lines; diagnostics go to stderr. The host exits at stdin EOF, so it
// never outlives its client.
import { createHash } from "node:crypto";
import { createReadStream, existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";

// The pins, duplicated from src/pins.lisp (byte-equal; tests/pin-test.lisp checks the Lisp side).
const UNKERNEL_VERSION = "0.2.0-261121-e69adda";
const ALPINE_IMAGE = "alpine-3.24.4-e0d59c37c0882d76";
const ALPINE_SHA256 = "02460df31c14772659bb347a651693ac9aaa7a8c2477f05e4e5e4d5c756dd567";
const GUEST_USER = "user";

const NOT_SET_UP = -32001;
const INVALID_PARAMS = -32602;
const METHOD_NOT_FOUND = -32601;
const HOST_ERROR = -32000;

// stdout is the RPC channel: nothing else may write there.
const rpcOut = process.stdout.write.bind(process.stdout);
for (const k of ["log", "info", "debug", "warn"]) console[k] = console.error;
const diag = (msg) => process.stderr.write(`unkernel-host: ${msg}\n`);

const here = path.dirname(fileURLToPath(import.meta.url));
const SETUP = path.resolve(here, "..", "scripts", "setup.sh");

function argHome() {
  const i = process.argv.indexOf("--home");
  const h = i >= 0 ? process.argv[i + 1] : undefined;
  if (!h) {
    diag("usage: node unkernel-host.mjs --home HOME");
    process.exit(64);
  }
  return path.resolve(h);
}
const HOME = argHome();

class RpcError extends Error {
  constructor(code, message, data) {
    super(message);
    this.code = code;
    this.data = data;
  }
}
const notSetUp = (what) =>
  new RpcError(NOT_SET_UP, `compute-backend-unkernel: ${HOME} is not set up (${what}): run \`sh ${SETUP} ${HOME}\` (scripts/setup.sh)`);
const invalid = (message) => new RpcError(INVALID_PARAMS, message);

// The installation in HOME

const modulePath = () => path.join(HOME, "node_modules", "unkernel", "dist", "node.mjs");
const distroPath = (version) => path.join(HOME, "distro", `v${version}`, "alpine.erofs");
const guestDir = () => path.join(HOME, "guest");

function installedVersion() {
  const p = path.join(HOME, "node_modules", "unkernel", "package.json");
  if (!existsSync(p) || !existsSync(modulePath())) throw notSetUp(`no unkernel in ${path.join(HOME, "node_modules")}`);
  return JSON.parse(readFileSync(p, "utf8")).version;
}

let uk;
async function sdk() {
  // Lazy: host.check on an empty HOME answers -32001 instead of failing at import.
  installedVersion();
  uk ??= await import(pathToFileURL(modulePath()).href);
  return uk;
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const h = createHash("sha256");
    createReadStream(file).on("error", reject).on("data", (b) => h.update(b)).on("end", () => resolve(h.digest("hex")));
  });
}

async function checkDistro(version) {
  const p = distroPath(version);
  if (!existsSync(p)) throw notSetUp(`no distro image ${p}`);
  return { path: p, sha256: await sha256(p) };
}

function guestManifest() {
  const json = path.join(guestDir(), "guest.json");
  const img = path.join(guestDir(), "guest.img");
  if (!existsSync(json) || !existsSync(img)) throw notSetUp(`no guest disk ${img}`);
  return JSON.parse(readFileSync(json, "utf8"));
}

async function hostCheck() {
  const version = installedVersion();
  const distro = await checkDistro(version);
  const g = guestManifest();
  return {
    node: process.version,
    unkernel: version,
    distroSha256: distro.sha256,
    guest: { unkernel: g.unkernel ?? null, image: g.image ?? null, packages: g.packages ?? [] },
  };
}

// The session (one per process)

let vm = null;
let opening = false;
const forwards = new Map(); // localPort → { server, sockets: Set }

const OPEN_KEYS = new Set(["unkernel", "distro", "disk", "mounts", "network", "memoryMiB", "cpus", "env", "directory", "tmp"]);

function isObject(x) {
  return x !== null && typeof x === "object" && !Array.isArray(x);
}

function checkAbsolute(p, what) {
  if (typeof p !== "string" || !p.startsWith("/") || p.split("/").includes("..") || /[\0,]/.test(p))
    throw invalid(`${what} ${JSON.stringify(p)}: an absolute path without .. or commas`);
}

function validateOpen(p) {
  if (!isObject(p)) throw invalid("session.open takes an object");
  for (const k of Object.keys(p)) if (!OPEN_KEYS.has(k)) throw invalid(`session.open: unknown key ${JSON.stringify(k)} (host functions stay off)`);
  if (p.network !== "none" && p.network !== "direct") throw invalid(`network ${JSON.stringify(p.network)}: "none" or "direct"`);
  if (!Array.isArray(p.mounts)) throw invalid("mounts: an array");
  for (const m of p.mounts) {
    if (!isObject(m)) throw invalid("a mount is an object");
    checkAbsolute(m.guest, "mount guest path");
    checkAbsolute(m.host, "mount host path");
    if (m.kind !== "directory" && m.kind !== "file") throw invalid(`mount kind ${JSON.stringify(m.kind)}`);
  }
  if (!Number.isInteger(p.memoryMiB) || p.memoryMiB < 256 || p.memoryMiB > 2048) throw invalid(`memoryMiB ${p.memoryMiB}: 256–2048`);
}

const parentOf = (p) => p.slice(0, p.replace(/\/+$/, "").lastIndexOf("/") + 1) || "/";
const under = (p, dir) => p === dir || p.startsWith(dir.endsWith("/") ? dir : dir + "/") || p + "/" === dir;

// The plan's mounts → what to mount, in path order. A directory is served by
// nodeFs (read-only unless the plan says read-write). A file is served as a
// one-file read-only tree at its parent path (9p mount points are directories),
// files sharing a parent in one tree; a file already served by a directory mount
// (same host file at that place) is skipped.
function mountList(mounts) {
  const dirs = mounts.filter((m) => m.kind === "directory");
  const groups = new Map();
  for (const f of mounts.filter((m) => m.kind === "file")) {
    const coveredBy = dirs.find((d) => under(f.guest, d.guest) &&
      path.join(d.host, path.relative(d.guest, f.guest)) === path.resolve(f.host));
    if (coveredBy) continue;
    const parent = parentOf(f.guest);
    if (!groups.has(parent)) groups.set(parent, {});
    const host = f.host;
    groups.get(parent)[path.basename(f.guest)] = () => readFileSync(host);
  }
  const list = [
    ...dirs.map((d) => ({ path: d.guest, kind: "directory", host: d.host, readOnly: d.readOnly !== false })),
    ...[...groups].map(([parent, tree]) => ({ path: parent, kind: "files", tree, readOnly: true })),
  ];
  // A read-only file tree needs a directory for every mount nested in it.
  for (const g of list.filter((x) => x.kind === "files")) {
    for (const o of list) {
      if (o === g || !o.path.startsWith(g.path) || o.path === g.path) continue;
      let node = g.tree;
      for (const part of o.path.slice(g.path.length).split("/").filter(Boolean)) {
        if (typeof node[part] !== "object" || node[part] instanceof Uint8Array) node[part] = {};
        node = node[part];
      }
    }
  }
  return list.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

async function sessionOpen(p) {
  if (vm || opening) throw invalid("session.open: this host already runs a kernel (one per process)");
  opening = true;
  validateOpen(p);
  const k = await sdk();
  const version = installedVersion();
  if (p.unkernel !== version || version !== UNKERNEL_VERSION)
    throw notSetUp(`installed unkernel ${version}, requested ${p.unkernel}, pinned ${UNKERNEL_VERSION}`);
  if (!isObject(p.distro) || p.distro.sha256 !== ALPINE_SHA256 || p.distro.image !== ALPINE_IMAGE)
    throw invalid(`distro ${JSON.stringify(p.distro)} is not the pinned ${ALPINE_IMAGE}`);
  // The distro image is HOME's own, checked before every boot.
  const distro = await checkDistro(version);
  if (distro.sha256 !== ALPINE_SHA256) throw notSetUp(`${distro.path} has SHA-256 ${distro.sha256}, not the pinned ${ALPINE_SHA256}`);
  // The guest disk: HOME's own, always a snapshot (writes stay in memory).
  if (!isObject(p.disk) || p.disk.snapshot !== true) throw invalid("disk: the guest disk is opened as a snapshot only");
  guestManifest();
  const disk = realpathSync(p.disk.path);
  if (path.dirname(disk) !== realpathSync(guestDir())) throw invalid(`disk ${p.disk.path} is not in ${guestDir()}`);
  const disks = [await k.openDisk(disk, { snapshot: true })];
  const netDevice = p.network === "direct"
    ? new k.NetStack({ backend: k.directBackend(), hostLoopback: false, log: () => {} })
    : undefined;
  const list = mountList(p.mounts);
  // Field by field, never spread from the request: no `commands`, no `mounts` option.
  const kernel = await k.createKernel({
    distro: distro.path,
    disks,
    net: netDevice,
    memoryMiB: p.memoryMiB,
    cpus: 1,
    log: () => {},
  });
  vm = kernel;
  kernel.exited.then((e) => {
    if (!closing) diag(`the kernel exited: ${e.kind} ${e.code} ${e.reason ?? ""}`);
  });
  await kernel.exec("true", []);
  const bootMs = Math.round(performance.now());
  // The kernel brings up a built-in dummy0 (CONFIG_DUMMY): no traffic, but the guest
  // should have no interface beyond lo (and eth0 with "direct").
  await kernel.exec("sh", ["-c", "ip link delete dummy0 2>/dev/null || true"], { user: "root" });
  // A file tree's parent must not be a guest directory it would hide.
  for (const m of list.filter((x) => x.kind === "files")) {
    const r = await kernel.exec("test", ["-e", m.path], { user: "root" });
    if (r.exitCode === 0) throw invalid(`a readable file's directory ${m.path} exists in the guest: mount the directory instead`);
  }
  for (const m of list) {
    const fs = m.kind === "files" ? new k.MemoryFs(m.tree) : k.nodeFs(m.host);
    await kernel.mount(m.path, fs, { readOnly: m.readOnly });
  }
  return { bootMs: Math.max(1, bootMs) };
}

function needVm() {
  if (!vm) throw invalid("no session: call session.open first");
  return vm;
}

function stringEnv(env) {
  const out = Object.create(null);
  if (env === undefined || env === null) return out;
  if (!isObject(env)) throw invalid("env: an object of strings");
  for (const [k, v] of Object.entries(env)) {
    if (typeof v !== "string") throw invalid(`env ${k}: not a string`);
    out[k] = v;
  }
  return out;
}

async function sessionExec(p) {
  const kernel = needVm();
  if (!isObject(p) || !Array.isArray(p.argv) || !p.argv.length || !p.argv.every((a) => typeof a === "string"))
    throw invalid("argv: a non-empty array of strings");
  const opts = {
    user: GUEST_USER,
    env: stringEnv(p.env), // the guest's login environment plus these: never process.env
    input: typeof p.input === "string" ? p.input : "",
  };
  if (typeof p.cwd === "string" && p.cwd) opts.cwd = p.cwd;
  let r;
  try {
    r = await kernel.exec(p.argv[0], p.argv.slice(1), opts);
  } catch (e) {
    // The guest could not exec the program (not found, not executable): as a shell does.
    if (e?.code === "EREMOTE" && /exec|No such file|not found|Permission denied/i.test(e.message ?? ""))
      return { exitCode: /Permission denied/i.test(e.message) ? 126 : 127, signal: null, stdout: "", stderr: `${e.message}\n` };
    throw e;
  }
  return { exitCode: r.exitCode, signal: r.signal, stdout: r.stdout, stderr: r.stderr };
}

function sessionForward(p) {
  const kernel = needVm();
  const guestPort = p?.guestPort;
  const localPort = p?.localPort ?? 0;
  if (!Number.isInteger(guestPort) || guestPort < 1 || guestPort > 65535) throw invalid("guestPort: 1–65535");
  if (!Number.isInteger(localPort) || localPort < 0 || localPort > 65535) throw invalid("localPort: 0–65535");
  const sockets = new Set();
  const server = net.createServer({ allowHalfOpen: true }, (sock) => {
    sockets.add(sock);
    sock.on("close", () => sockets.delete(sock));
    sock.on("error", () => sock.destroy());
    sock.pause();
    kernel.connect(guestPort).then((gs) => {
      const writer = gs.writable.getWriter();
      sock.on("data", (b) => {
        sock.pause();
        writer.write(b).then(() => sock.resume(), () => sock.destroy());
      });
      sock.on("end", () => writer.close().catch(() => {}));
      sock.on("close", () => gs.close().catch(() => {}));
      sock.resume();
      (async () => {
        const reader = gs.readable.getReader();
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            if (!sock.write(value)) await new Promise((r) => sock.once("drain", r));
          }
          sock.end();
        } catch {
          sock.destroy();
        }
      })();
    }, () => sock.destroy());
  });
  return new Promise((resolve, reject) => {
    server.once("error", (e) => reject(new RpcError(HOST_ERROR, `forward on 127.0.0.1:${localPort}: ${e.message}`)));
    // 127.0.0.1 only, whatever the request says.
    server.listen({ host: "127.0.0.1", port: localPort }, () => {
      const port = server.address().port;
      forwards.set(port, { server, sockets });
      resolve({ localPort: port });
    });
  });
}

function closeForward(port) {
  const f = forwards.get(port);
  if (!f) return false;
  forwards.delete(port);
  f.server.close();
  for (const s of f.sockets) s.destroy();
  return true;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let closing = false;

async function sessionClose() {
  closing = true;
  for (const port of [...forwards.keys()]) closeForward(port);
  if (vm) {
    const kernel = vm;
    await Promise.race([kernel.exec("sudo", ["poweroff"]).catch(() => {}), sleep(5000)]);
    await Promise.race([kernel.exited, sleep(3000)]);
    await kernel.stop().catch(() => {});
  }
  return {};
}

const methods = {
  "host.check": () => hostCheck(),
  "session.open": (p) => sessionOpen(p),
  "session.exec": (p) => sessionExec(p),
  "session.forward": (p) => sessionForward(p),
  "session.unforward": (p) => ({ closed: closeForward(p?.localPort) }),
  "session.close": () => sessionClose(),
};

function send(msg) {
  rpcOut(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n");
}

async function handle(msg) {
  const id = msg?.id;
  const reply = id !== undefined;
  if (!isObject(msg) || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
    if (reply) send({ id: id ?? null, error: { code: -32600, message: "Invalid Request" } });
    return;
  }
  const fn = methods[msg.method];
  if (!fn) {
    if (reply) send({ id, error: { code: METHOD_NOT_FOUND, message: `Method not found: ${msg.method}` } });
    return;
  }
  try {
    const result = await fn(Array.isArray(msg.params) ? {} : msg.params ?? {});
    if (reply) send({ id, result: result ?? {} });
  } catch (e) {
    const error = e instanceof RpcError
      ? { code: e.code, message: e.message, ...(e.data !== undefined ? { data: e.data } : {}) }
      : { code: HOST_ERROR, message: `${e?.name ?? "Error"}${e?.code ? ` ${e.code}` : ""}: ${e?.message ?? e}` };
    if (reply) send({ id, error });
  }
}

let shuttingDown = false;
async function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  closing = true;
  for (const port of [...forwards.keys()]) closeForward(port);
  setTimeout(() => process.exit(code), 2000).unref();
  try { await vm?.stop(); } catch {}
  process.exit(code);
}

process.on("uncaughtException", (e) => { diag(`uncaught: ${e?.stack ?? e}`); shutdown(70); });
process.on("unhandledRejection", (e) => { diag(`unhandled rejection: ${e?.stack ?? e}`); shutdown(70); });

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    send({ id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }
  // Each request is its own task: a long session.exec never blocks forward or close.
  handle(msg);
});
// The client went away: the kernel goes too.
rl.on("close", () => shutdown(0));
