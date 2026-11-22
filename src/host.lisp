(in-package #:compute-backend-unkernel)

;;; The Node host process and the setup directory (HOME).
;;;
;;; HOME layout, written by scripts/setup.sh [HOME] (the one setup step; the
;;; backend never downloads anything itself):
;;;   HOME/node_modules/           npm ci --ignore-scripts of host/package.json + lockfile
;;;   HOME/distro/                 UNKERNEL_CACHE_DIR: fetchDistro("alpine") (alpine.erofs,
;;;                                distros.json of +UNKERNEL-VERSION+)
;;;   HOME/guest/guest.img         the ext4 guest data disk (+GUEST-PACKAGES+ installed)
;;;   HOME/guest/guest.json        {"unkernel", "image", "packages"} it was built from
;;;
;;; The host: `node host/unkernel-host.mjs --home HOME`, newline JSON-RPC 2.0 on
;;; stdio (rpc-backend-stdio), one kernel per process. It imports unkernel from
;;; HOME/node_modules by absolute path. Methods (params / result are JSON objects):
;;;   host.check      {}                          → {"node", "unkernel", "distroSha256",
;;;                                                  "guest": {"unkernel", "image", "packages"}}
;;;                   or error -32001, message = the reason (names scripts/setup.sh)
;;;   session.open    PLAN-REQUEST                → {"bootMs"}            (once per process)
;;;   session.exec    {"argv", "cwd", "env", "input", "timeoutMs"}
;;;                                               → {"exitCode", "signal", "stdout", "stderr"}
;;;   session.forward {"guestPort", "localPort"}  → {"localPort"}  (listens on 127.0.0.1 only)
;;;   session.unforward {"localPort"}             → {"closed": true|false}
;;;   session.close   {}                          → {} after the guest's poweroff; then the
;;;                                                  host exits at stdin EOF
;;; createKernel is never given `commands` (host functions) and the net backend is
;;; directBackend() with hostLoopback off, only for "network": "direct".
;;;
;;; Given (contract): the HOME default and the asset paths, HOST-COMMAND.
;;; Stubbed: PROBE-NODE, HOST-CHECK.

(defun default-unkernel-home ()
  "COMPUTE_UNKERNEL_HOME, else $XDG_CACHE_HOME/compute-backend-unkernel/<+UNKERNEL-VERSION+>/
\(XDG_CACHE_HOME defaults to ~/.cache/). A directory pathname; it may not exist."
  (let ((env (uiop:getenv "COMPUTE_UNKERNEL_HOME")))
    (if (and env (plusp (length env)))
        (uiop:ensure-directory-pathname (uiop:parse-native-namestring env))
        (uiop:ensure-directory-pathname
         (merge-pathnames (format nil "compute-backend-unkernel/~a/" +unkernel-version+)
                          (uiop:xdg-cache-home))))))

(defun host-directory ()
  "host/ of this system: unkernel-host.mjs, package.json, package-lock.json."
  (asdf:system-relative-pathname "compute-backend-unkernel" "host/"))

(defun host-script-pathname ()
  (merge-pathnames "unkernel-host.mjs" (host-directory)))

(defun setup-script-pathname ()
  "scripts/setup.sh: `sh setup.sh [HOME]` fills HOME (see the layout above)."
  (asdf:system-relative-pathname "compute-backend-unkernel" "scripts/setup.sh"))

(defun host-command (backend)
  "argv of BACKEND's host process: (node script \"--home\" home), native namestrings."
  (list (unkernel-backend-node backend)
        (uiop:native-namestring (host-script-pathname))
        "--home"
        (uiop:native-namestring (unkernel-backend-home backend))))

(defun probe-node (node)
  "Run `NODE --version` through process-protocol (10 s timeout). → (values major
version-string) when it ran and printed vMAJOR.MINOR.PATCH, else (values NIL reason):
the reason names NODE and \"Node 24\". Never signals for a missing or broken NODE."
  (declare (ignore node))
  (%unkernel0-pending "probe-node"))

(defun host-check (backend)
  "Start BACKEND's host, call host.check, stop it. → a plist
  (:node \"v26.12.1\" :unkernel +UNKERNEL-VERSION+ :distro-sha256 +ALPINE-SHA256+
   :guest-unkernel … :guest-image … :guest-packages (\"sbcl=2.6.5-r0\"))
Signals CONFINEMENT-UNAVAILABLE (reason = the host's message, naming scripts/setup.sh)
when HOME is not set up, or when what it reports differs from the pins (the installed
unkernel version, the distro SHA-256, a guest disk built for another version, image or
package set)."
  (declare (ignore backend))
  (%unkernel0-pending "host-check"))
