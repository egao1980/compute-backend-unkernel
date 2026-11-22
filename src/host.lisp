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
;;; Implemented (R4h-4a): PROBE-NODE, HOST-CHECK.

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
  (flet ((no (format &rest args)
           (values nil (format nil "~a: ~?; compute-backend-unkernel needs Node ~d or newer (Node 24+, set :node or COMPUTE_UNKERNEL_NODE)"
                               node format args +node-min-major+))))
    (multiple-value-bind (code out err)
        ;; A predicate by contract: a NODE that cannot be run is a reason, not an error.
        (handler-case (pp:run (list node "--version")
                              :output :string :error-output :string :timeout 10)
          (pp:process-error (e) (return-from probe-node (no "cannot be run (~a)" e))))
      (let* ((version (string-trim '(#\Space #\Tab #\Newline #\Return) (or out "")))
             (parts (%parse-node-version version)))
        (cond ((not (eql code 0))
               (no "`--version` exited ~a~@[ (~a)~]" code
                   (let ((e (string-trim '(#\Space #\Newline) (or err ""))))
                     (and (plusp (length e)) e))))
              ((null parts) (no "printed ~s, not a Node version (vMAJOR.MINOR.PATCH)" version))
              ((< (first parts) +node-min-major+) (no "is ~a, too old" version))
              (t (values (first parts) version)))))))

(defun %parse-node-version (string)
  "\"vMAJOR.MINOR.PATCH\" → (major minor patch), else NIL."
  (when (and (> (length string) 1) (char= #\v (char string 0)))
    (let ((fields (uiop:split-string (subseq string 1) :separator ".")))
      (when (and (= 3 (length fields))
                 (every (lambda (f) (and (plusp (length f)) (every #'digit-char-p f))) fields))
        (mapcar #'parse-integer fields)))))

(defparameter +host-not-set-up+ -32001
  "The host's JSON-RPC error code for a HOME that scripts/setup.sh has not (fully) filled.")

(defun %setup-hint (backend)
  (format nil "run `sh ~a ~a`"
          (uiop:native-namestring (setup-script-pathname))
          (uiop:native-namestring (unkernel-backend-home backend))))

(defun %unavailable (backend format &rest args)
  (error 'sc:confinement-unavailable :backend backend :reason (format nil "~?" format args)))

(defun %host-transport (backend)
  "A client transport whose child is BACKEND's host process (launched on the first call)."
  (rpc-backend-stdio:make-stdio-rpc-transport :command (host-command backend)))

(defun %json-get (object key)
  (and (hash-table-p object) (gethash key object)))

(defun %json-strings (value)
  (and (or (and (vectorp value) (not (stringp value))) (listp value))
       (every #'stringp value)
       (coerce value 'list)))

(defun host-check (backend)
  "Start BACKEND's host, call host.check, stop it. → a plist
  (:node \"v26.12.1\" :unkernel +UNKERNEL-VERSION+ :distro-sha256 +ALPINE-SHA256+
   :guest-unkernel … :guest-image … :guest-packages (\"sbcl=2.6.5-r0\"))
Signals CONFINEMENT-UNAVAILABLE (reason = the host's message, naming scripts/setup.sh)
when HOME is not set up, or when what it reports differs from the pins (the installed
unkernel version, the distro SHA-256, a guest disk built for another version, image or
package set)."
  (let* ((transport (%host-transport backend))
         (info (unwind-protect
                    (handler-case
                        (rpc-protocol:rpc-call "host.check" nil :transport transport :timeout 60)
                      (rpc-protocol:rpc-error (e)
                        (if (eql +host-not-set-up+ (rpc-protocol:rpc-error-code e))
                            (%unavailable backend "~a" (rpc-protocol:rpc-error-message e))
                            (%unavailable backend "the unkernel host ~a failed (~a): ~a"
                                          (uiop:native-namestring (host-script-pathname)) e
                                          (%setup-hint backend))))
                      (pp:process-error (e)
                        (%unavailable backend "the unkernel host could not be started (~a): ~a"
                                      e (%setup-hint backend))))
                 (rpc-backend-stdio:close-stdio-rpc-transport transport :timeout 5)))
         (guest (%json-get info "guest"))
         (plist (list :node (%json-get info "node")
                      :unkernel (%json-get info "unkernel")
                      :distro-sha256 (%json-get info "distroSha256")
                      :guest-unkernel (%json-get guest "unkernel")
                      :guest-image (%json-get guest "image")
                      :guest-packages (%json-strings (%json-get guest "packages")))))
    (loop for (key want what) in `((:unkernel ,+unkernel-version+ "the installed unkernel")
                                   (:distro-sha256 ,+alpine-sha256+ "the distro's SHA-256")
                                   (:guest-unkernel ,+unkernel-version+ "the guest disk's unkernel")
                                   (:guest-image ,+alpine-image+ "the guest disk's distro image")
                                   (:guest-packages ,+guest-packages+ "the guest disk's packages"))
          for got = (getf plist key)
          unless (equal want got)
            do (%unavailable backend "~a in ~a is ~s, not the pinned ~s: ~a"
                             what (uiop:native-namestring (unkernel-backend-home backend))
                             got want (%setup-hint backend)))
    (unless (stringp (getf plist :node))
      (%unavailable backend "the unkernel host did not report its Node version: ~a"
                    (%setup-hint backend)))
    plist))
