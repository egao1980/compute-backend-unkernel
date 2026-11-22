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
# Contract stub (R4h-4a).
echo "compute-backend-unkernel: scripts/setup.sh is pending (R4h-4a)" >&2
exit 2
