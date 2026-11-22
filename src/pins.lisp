(in-package #:compute-backend-unkernel)

;;; Pins. unkernel is younger than the two-week pin rule allows; the exception is
;;; recorded in cl-stack docs/capabilities/confinement.md § R4h-4: pinned exactly,
;;; and the whole suite plus the extra isolation laws re-run on every bump
;;; (egao1980/compute-backend-unkernel#1). host/package.json and
;;; host/package-lock.json must agree with these (tests/pin-test.lisp).

(defparameter +unkernel-version+ "0.2.0-261121-e69adda"
  "The npm version of unkernel the host runs, exactly.")

(defparameter +unkernel-integrity+
  "sha512-RcN062gFjX73dIDStLzu8aSVbMhn3+GhSARIeVo2z2+FNo4+jtpvK8MNEmirr7TO9y05V/jIT2tZmu35wkqbcA=="
  "The lockfile integrity of that tarball.")

(defparameter +unkernel-tarball+
  "https://registry.npmjs.org/unkernel/-/unkernel-0.2.0-261121-e69adda.tgz"
  "The lockfile's resolved URL of that tarball.")

(defparameter +alpine-image+ "alpine-3.24.4-e0d59c37c0882d76"
  "The distro image of the unkernel release (distros.json \"image\").")

(defparameter +alpine-sha256+
  "02460df31c14772659bb347a651693ac9aaa7a8c2477f05e4e5e4d5c756dd567"
  "SHA-256 of that release's alpine.erofs, checked before every boot.")

(defparameter +guest-packages+ '("sbcl=2.6.5-r0")
  "apk packages on the guest data disk (Alpine community), exactly.")

(defparameter +node-min-major+ 24
  "The oldest Node major unkernel supports (its package.json engines).")

(defparameter +unkernel-features+
  '(:filesystem :read-system :network-none :network-allow :memory-limit)
  "What this backend enforces (CONFINEMENT-FEATURES), in +CONFINEMENT-FEATURES+ order.")

(defparameter +default-memory-mib+ 1024)
(defparameter +min-memory-mib+ 256)
(defparameter +max-memory-mib+ 2048
  "32-bit wasm memory: the guest cannot have more.")

(defparameter +guest-home+ "/home/user/"
  "The distro user's home (uid 1000): the start directory when nothing else is.")

(defparameter +host-command-port+ 1020
  "unkernel's vsock port for host functions (createKernel {commands}); never served here.")

(defparameter +unkernel-placement+ :microvm
  "The H4f placement (`lisp_session_open :placement :local|:container|:microvm`) this
backend serves: :MICROVM, a guest kernel of its own, attached from the host only over
vsock (FORWARD-PORT). R4h-4b's Swank session image is opened with it.")
