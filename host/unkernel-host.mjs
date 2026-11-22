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
// Contract stub (R4h-4a): answers every request with an error.
import { createInterface } from "node:readline";

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg && msg.id !== undefined) {
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0", id: msg.id,
      error: { code: -32000, message: `R4h-4a pending: ${msg.method}` },
    }) + "\n");
  }
});
