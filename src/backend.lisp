(in-package #:compute-backend-unkernel)

;;; UNKERNEL-BACKEND — a session backend. It subclasses CONFINING-BACKEND so the
;;; confinement value, CONFINEMENT-FEATURES / -AVAILABLE-P and compute-protocol's
;;; suite apply, but it is not a per-command prefix: BACKEND-CONFINE-ARGV refuses,
;;; so CONFINE-COMMAND / RUN-CONFINED do not apply (0.1.0). Sessions: session.lisp.
;;;
;;; Given (contract): the class, the constructor and readers, the features, the
;;; BACKEND-CONFINE-ARGV refusal. Implemented (R4h-4a): CONFINEMENT-AVAILABLE-P.

(defclass unkernel-backend (sc:confining-backend)
  ((node :initarg :node :initform nil
         :documentation "The Node executable (a string), or NIL: COMPUTE_UNKERNEL_NODE, else \"node\" on PATH.")
   (home :initarg :home :initform nil
         :documentation "The setup directory (scripts/setup.sh), or NIL: DEFAULT-UNKERNEL-HOME.")
   (memory-mib :initarg :memory-mib :initform +default-memory-mib+
               :reader unkernel-backend-memory-mib
               :documentation "Guest memory when neither the spec nor the confinement asks for less.")
   (boot-timeout :initarg :boot-timeout :initform 120
                 :reader unkernel-backend-boot-timeout
                 :documentation "Seconds OPEN-SANDBOX waits for the kernel's first exec.")
   (availability :initform nil :accessor %backend-availability
                 :documentation "NIL until probed, then (ok . reason): probed once per backend."))
  (:documentation
   "Sessions in unkernel (Linux compiled to WebAssembly) under a Node host process, one
kernel per process. The fallback sandbox: portable, no hypervisor or root, 26–34x slower
than native on compute. Never chosen automatically."))

(defun unkernel-backend-p (object)
  (typep object 'unkernel-backend))

(defun make-unkernel-backend (&key node home (memory-mib +default-memory-mib+) (boot-timeout 120))
  "An UNKERNEL-BACKEND. NODE: the Node executable (NIL → COMPUTE_UNKERNEL_NODE, else
\"node\"). HOME: the directory scripts/setup.sh filled (NIL → DEFAULT-UNKERNEL-HOME).
MEMORY-MIB: an integer in [+MIN-MEMORY-MIB+, +MAX-MEMORY-MIB+]. BOOT-TIMEOUT: seconds.
Nothing is probed here."
  (check-type node (or null string pathname))
  (check-type home (or null string pathname))
  (check-type memory-mib integer)
  (unless (<= +min-memory-mib+ memory-mib +max-memory-mib+)
    (error 'type-error :datum memory-mib
                       :expected-type `(integer ,+min-memory-mib+ ,+max-memory-mib+)))
  (check-type boot-timeout (real (0)))
  (make-instance 'unkernel-backend
                 :node (and node (if (pathnamep node) (uiop:native-namestring node) node))
                 :home (and home (uiop:ensure-directory-pathname home))
                 :memory-mib memory-mib
                 :boot-timeout boot-timeout))

(defun use-unkernel-backend (&rest args)
  "Make an UNKERNEL-BACKEND (ARGS as MAKE-UNKERNEL-BACKEND) the *COMPUTE-BACKEND*."
  (setf sc:*compute-backend* (apply #'make-unkernel-backend args)))

(defun unkernel-backend-node (backend)
  "The Node executable BACKEND runs: its :NODE, else COMPUTE_UNKERNEL_NODE, else \"node\"."
  (or (slot-value backend 'node)
      (let ((env (uiop:getenv "COMPUTE_UNKERNEL_NODE")))
        (and env (plusp (length env)) env))
      "node"))

(defun unkernel-backend-home (backend)
  "BACKEND's setup directory (a directory pathname): its :HOME, else DEFAULT-UNKERNEL-HOME."
  (or (slot-value backend 'home) (default-unkernel-home)))

(defmethod sc:confinement-features ((backend unkernel-backend))
  (copy-list +unkernel-features+))

(defmethod sc:confinement-available-p ((backend unkernel-backend))
  "→ (values ok reason), probed once per backend (cached in %BACKEND-AVAILABILITY), in
this order, the first failure giving the reason (a string):
  Windows host                → \"… does not run on Windows hosts …\"
  Node missing                → names the Node executable and \"Node 24\"
  Node older than 24          → names the version found and \"Node 24\"
  HOST-CHECK fails            → its reason; every HOME problem names scripts/setup.sh
Never signals for these: a reason is returned instead."
  (let ((probed (or (%backend-availability backend)
                    (setf (%backend-availability backend) (%probe-availability backend)))))
    (values (car probed) (cdr probed))))

(defun %probe-availability (backend)
  "→ (ok . reason), the checks of CONFINEMENT-AVAILABLE-P in order."
  (if (uiop:os-windows-p)
      (cons nil "compute-backend-unkernel does not run on Windows hosts (0.1.0): use a Unix host with Node 24+")
      (multiple-value-bind (major reason) (probe-node (unkernel-backend-node backend))
        (if (null major)
            (cons nil reason)
            (handler-case (progn (host-check backend) (cons t nil))
              (sc:confinement-unavailable (e)
                (cons nil (sc:confinement-unavailable-reason e))))))))

(defmethod sc:backend-confine-argv ((backend unkernel-backend) confinement argv directory tmp)
  (declare (ignore confinement argv directory tmp))
  (error 'sc:compute-error
         :message "compute-backend-unkernel is a session backend: use OPEN-SANDBOX / RUN-SANDBOXED, not CONFINE-COMMAND"))
