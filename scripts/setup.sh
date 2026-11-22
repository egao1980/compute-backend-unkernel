#!/bin/sh
# compute-backend-unkernel setup: the one step that downloads anything.
#
#   sh scripts/setup.sh [HOME]
#
# HOME defaults to $COMPUTE_UNKERNEL_HOME, else
# ${XDG_CACHE_HOME:-$HOME/.cache}/compute-backend-unkernel/<unkernel version>/.
# Fills (idempotent; each step skipped when already done and matching the pins):
#   HOME/node_modules/      npm ci --ignore-scripts of host/package.json + lockfile
#   HOME/distro/            fetchDistro("alpine") (UNKERNEL_CACHE_DIR), SHA-256 checked
#   HOME/guest/guest.img    ext4 data disk from the bundled template, booted once with
#                           the network to `apk add` the pinned packages (sbcl=2.6.5-r0)
#   HOME/guest/guest.json   {"unkernel", "image", "packages"}
# Needs Node 24+ and npm. Fails loudly (non-zero) when a pinned item is unavailable.
#
# The pins are duplicated from src/pins.lisp (keep them byte-equal). The Node
# code runs here (node --input-type=module), never in the session host: only
# setup boots a kernel with the network for its own sake.
set -eu

UNKERNEL_VERSION="0.2.0-261121-e69adda"
ALPINE_IMAGE="alpine-3.24.4-e0d59c37c0882d76"
ALPINE_SHA256="02460df31c14772659bb347a651693ac9aaa7a8c2477f05e4e5e4d5c756dd567"
GUEST_PACKAGES="sbcl=2.6.5-r0"
NODE_MIN_MAJOR=24

say() { printf 'setup.sh: %s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
host_dir=$(CDPATH= cd -- "$script_dir/../host" && pwd)

if [ $# -ge 1 ] && [ -n "$1" ]; then
    H=$1
elif [ -n "${COMPUTE_UNKERNEL_HOME:-}" ]; then
    H=$COMPUTE_UNKERNEL_HOME
else
    H=${XDG_CACHE_HOME:-$HOME/.cache}/compute-backend-unkernel/$UNKERNEL_VERSION
fi
mkdir -p "$H"
H=$(CDPATH= cd -- "$H" && pwd)
umask 077

# Node 24+ and npm
command -v node >/dev/null 2>&1 || die "node is not on PATH (Node $NODE_MIN_MAJOR+ is needed)"
command -v npm >/dev/null 2>&1 || die "npm is not on PATH"
node_version=$(node --version)
node_major=$(printf '%s' "$node_version" | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')
[ -n "$node_major" ] && [ "$node_major" -ge "$NODE_MIN_MAJOR" ] \
    || die "node is $node_version: Node $NODE_MIN_MAJOR or newer is needed"
say "HOME $H, node $node_version"

# 1. The pinned host modules: npm ci, never npm install.
installed=""
if [ -f "$H/node_modules/unkernel/package.json" ]; then
    installed=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' \
                    "$H/node_modules/unkernel/package.json")
fi
if [ "$installed" = "$UNKERNEL_VERSION" ] \
   && cmp -s "$host_dir/package.json" "$H/package.json" \
   && cmp -s "$host_dir/package-lock.json" "$H/package-lock.json"; then
    say "node_modules: unkernel $installed (kept)"
else
    cp "$host_dir/package.json" "$host_dir/package-lock.json" "$H/"
    (cd "$H" && npm ci --ignore-scripts --no-audit --no-fund) >&2 || die "npm ci failed in $H"
    installed=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' \
                    "$H/node_modules/unkernel/package.json")
    [ "$installed" = "$UNKERNEL_VERSION" ] || die "npm installed unkernel $installed, not the pinned $UNKERNEL_VERSION"
    say "node_modules: unkernel $installed (installed)"
fi

# 2. The distro (3) and the guest disk (4), driven through the SDK.
export SETUP_HOME="$H" UNKERNEL_VERSION ALPINE_IMAGE ALPINE_SHA256 GUEST_PACKAGES
export UNKERNEL_CACHE_DIR="$H/distro"
node --input-type=module <<'EOF'
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const env = process.env;
const H = env.SETUP_HOME;
const say = (m) => process.stderr.write(`setup.sh: ${m}\n`);
const die = (m) => { say(`error: ${m}`); process.exit(1); };
const uk = await import(pathToFileURL(path.join(H, "node_modules/unkernel/dist/node.mjs")).href);
const sha256 = (file) => createHash("sha256").update(readFileSync(file)).digest("hex");

// 3. The pinned distro image, the SDK checks size and SHA-256; we check the pin again.
const distro = await uk.fetchDistro("alpine", { cacheDir: env.UNKERNEL_CACHE_DIR, local: false })
  .catch((e) => die(`fetchDistro("alpine"): ${e?.message ?? e}`));
const index = JSON.parse(readFileSync(path.join(path.dirname(distro), "distros.json"), "utf8"));
const entry = index.distros.find((d) => d.name === "alpine");
if (entry?.image !== env.ALPINE_IMAGE) die(`the release's alpine image is ${entry?.image}, not the pinned ${env.ALPINE_IMAGE}`);
const sum = sha256(distro);
if (sum !== env.ALPINE_SHA256) die(`${distro} has SHA-256 ${sum}, not the pinned ${env.ALPINE_SHA256}`);
if (distro !== path.join(H, "distro", `v${env.UNKERNEL_VERSION}`, "alpine.erofs")) die(`unexpected distro path ${distro}`);
say(`distro: ${distro} (${env.ALPINE_IMAGE}, SHA-256 ok)`);

// 4. The guest disk, unless guest.json already says it was built from these pins.
const dir = path.join(H, "guest");
const img = path.join(dir, "guest.img");
const manifest = path.join(dir, "guest.json");
const packages = env.GUEST_PACKAGES.split(/\s+/).filter(Boolean);
const want = { unkernel: env.UNKERNEL_VERSION, image: env.ALPINE_IMAGE, packages };
const have = existsSync(manifest) ? (() => { try { return JSON.parse(readFileSync(manifest, "utf8")); } catch { return null; } })() : null;
if (have && existsSync(img) && JSON.stringify(have) === JSON.stringify(want)) {
  say(`guest disk: ${img} (kept)`);
  process.exit(0);
}
mkdirSync(dir, { recursive: true });
rmSync(manifest, { force: true });
const partial = path.join(dir, "guest.img.partial");
for (const f of [partial, `${partial}.kwsnap`]) rmSync(f, { force: true });
const mod = await WebAssembly.compile(readFileSync(fileURLToPath(uk.bundledKernelUrl)));
const template = uk.bundledBoot(mod).datadisk;
if (!template) die("the bundled kernel has no data disk template");
await uk.createImageFromKwsparse(partial, template);
say(`guest disk: booting once with the network to install ${packages.join(" ")}`);
const vm = await uk.createKernel({
  distro,
  disks: [await uk.openDisk(partial)],
  net: new uk.NetStack({ backend: uk.directBackend(), hostLoopback: false, log: () => {} }),
  memoryMiB: 1024,
  cpus: 1,
  log: () => {},
});
const run = async (file, args, what) => {
  const r = await vm.exec(file, args, { user: "root", timeout: 120000 });
  if (r.exitCode !== 0) {
    await vm.stop().catch(() => {});
    rmSync(partial, { force: true });
    die(`${what} failed (exit ${r.exitCode ?? `signal ${r.signal}`}):\n${r.stdout}${r.stderr}`);
  }
  return r.stdout;
};
await run("sh", ["-c", "grep -q '/community$' /etc/apk/repositories || sed -n 1p /etc/apk/repositories | sed 's/main$/community/' >> /etc/apk/repositories"],
          "enabling the Alpine community repository");
await run("apk", ["add", "--no-cache", ...packages], `apk add ${packages.join(" ")}`);
for (const p of packages) await run("apk", ["info", "-e", p.replace(/=.*/, "")], `apk info -e ${p}`);
const sbcl = await run("sbcl", ["--version"], "sbcl --version");
const sbclPin = packages.find((p) => p.startsWith("sbcl="));
if (sbclPin && !sbcl.startsWith(`SBCL ${sbclPin.slice(5).replace(/-r\d+$/, "")}`)) die(`the guest's ${sbcl.trim()} is not ${sbclPin}`);
await vm.sync().catch(() => {});
await Promise.race([vm.exec("poweroff", [], { user: "root" }).catch(() => {}), new Promise((r) => setTimeout(r, 15000))]);
await Promise.race([vm.exited, new Promise((r) => setTimeout(r, 10000))]);
await vm.stop().catch(() => {});
rmSync(`${partial}.kwsnap`, { force: true });
renameSync(partial, img);
// Written last: it marks the disk complete.
writeFileSync(manifest, JSON.stringify(want) + "\n");
say(`guest disk: ${img} (${sbcl.trim()})`);
process.exit(0);
EOF
say "done: $H"
