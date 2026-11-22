(in-package #:compute-backend-unkernel)

;;; Conditions. Everything else is compute-protocol's own vocabulary:
;;;   CONFINEMENT-UNAVAILABLE  no Node 24+, Windows, HOME not set up (reason string)
;;;   CONFINEMENT-UNSUPPORTED  a feature outside +UNKERNEL-FEATURES+ (MISSING)
;;;   INVALID-CONFINEMENT      a confinement field this backend cannot honour
;;;   SANDBOX-DENIED           a spec field it refuses (POLICY :egress :lisp :cpu-limit :memory-limit)
;;;   SANDBOX-TIMEOUT          a wall-clock passed: the session was killed (restart ABORT-EXECUTION)

(define-condition unkernel-error (sc:compute-error)
  ((code :initarg :code :reader unkernel-error-code :initform nil)
   (data :initarg :data :reader unkernel-error-data :initform nil))
  (:report (lambda (c s)
             (format s "unkernel host error~@[ ~a~]~@[: ~a~]"
                     (unkernel-error-code c)
                     (sc:compute-error-message c))))
  (:documentation "The Node host answered a JSON-RPC error (CODE, DATA as sent), died, or
the kernel failed to boot. A session whose host died is closed."))

(define-condition unkernel-session-closed (sc:compute-error)
  ((session :initarg :session :reader unkernel-session-closed-session :initform nil))
  (:report (lambda (c s)
             (format s "the unkernel session is closed~@[: ~a~]" (sc:compute-error-message c))))
  (:documentation "SESSION-EXEC, RUN-SANDBOXED or FORWARD-PORT on a session that was closed,
or killed by a timeout or a host failure."))
