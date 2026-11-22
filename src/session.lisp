(in-package #:compute-backend-unkernel)

;;; Sessions: one Node host process = one kernel = one session.
;;;
;;; Given (contract): the class and its readers, UNKERNEL-SESSION-ALIVE-P.
;;; Stubbed: OPEN-SANDBOX, SESSION-EXEC, RUN-SANDBOXED (backend and session),
;;; CLOSE-SANDBOX, FORWARD-PORT, CLOSE-FORWARD, UNKERNEL-SESSION-PID.
;;; The implementation may add internal slots (transport, lock, …).

(defclass unkernel-session (sc:sandbox-session)
  ((plan :initarg :plan :reader unkernel-session-plan
         :documentation "The UNKERNEL-PLAN the kernel was booted with (with its TMP).")
   (state :initform :open :accessor %session-state
          :documentation ":OPEN, :CLOSED (CLOSE-SANDBOX) or :KILLED (a timeout or a host failure).")
   (boot-ms :initform nil :accessor %session-boot-ms)
   (forwards :initform '() :accessor %session-forwards
             :documentation "Open forwards: (local-port . guest-port), newest first."))
  (:documentation "A booted unkernel kernel in its own Node host process."))

(defun unkernel-session-p (object)
  (typep object 'unkernel-session))

(defun unkernel-session-alive-p (session)
  "True until the session is closed or killed."
  (eq (%session-state session) :open))

(defun unkernel-session-boot-ms (session)
  "Milliseconds from the host's start to the kernel's first exec (session.open's bootMs)."
  (%session-boot-ms session))

(defun unkernel-session-forwards (session)
  "The local (127.0.0.1) ports of SESSION's open forwards, ascending."
  (sort (mapcar #'car (%session-forwards session)) #'<))

(defun unkernel-session-pid (session)
  "The host process's pid (an integer), also after it exited."
  (declare (ignore session))
  (%unkernel0-pending "unkernel-session-pid"))

(defmethod sc:open-sandbox ((backend unkernel-backend) spec)
  "→ an UNKERNEL-SESSION. In order, nothing created before the step that needs it:
CONFINEMENT-AVAILABLE-P (else CONFINEMENT-UNAVAILABLE with its reason); PLAN-SESSION
dry (its refusals); the private temp dir (a fresh stack-compute-<16 hex>/ under the
physical system temp dir, when the confinement's :TMP is :PRIVATE); the plan with it;
the host process (HOST-COMMAND, through rpc-backend-stdio :COMMAND); session.open with
PLAN-REQUEST, waiting UNKERNEL-BACKEND-BOOT-TIMEOUT seconds. A failure after the temp dir
exists kills the host and deletes the temp dir, then signals (a boot failure or a host
error → UNKERNEL-ERROR)."
  (declare (ignore spec))
  (%unkernel0-pending "open-sandbox"))

(defun session-exec (session argv &key input env directory wall-clock)
  "Run ARGV (strings) in SESSION's guest as the distro user → (values exit-code stdout
stderr). INPUT: a string for stdin (else empty). ENV: alist added after PLAN-ENV (wins).
DIRECTORY: a guest path (default PLAN-DIRECTORY). WALL-CLOCK: seconds or NIL. A program
killed by a signal exits 128 + signo. Text is UTF-8.
WALL-CLOCK passed → the session is killed (the host process killed, forwards closed,
the temp dir deleted, state :KILLED), then SANDBOX-TIMEOUT (:limit WALL-CLOCK) is
signalled with restart ABORT-EXECUTION (→ NIL). A closed or killed session →
UNKERNEL-SESSION-CLOSED. The host dying or answering an error → the session is killed,
then UNKERNEL-ERROR."
  (declare (ignore session argv input env directory wall-clock))
  (%unkernel0-pending "session-exec"))

(defmethod sc:run-sandboxed ((session unkernel-session) spec)
  "SPEC NIL → the session spec's :COMMAND. Otherwise SPEC's :COMMAND with its :ENV and
:WALL-CLOCK; its :CONFINEMENT, :MOUNTS and :NETWORK must be absent (NIL, NIL, :NONE) or
equal to the session spec's, else COMPUTE-ERROR (mounts and network are fixed at open);
:CODE → SANDBOX-DENIED :policy :lisp; no command → COMPUTE-ERROR. → a SANDBOX-RESULT
\(exit code, stdout, stderr, the spec's :ARTIFACTS), or NIL after ABORT-EXECUTION."
  (declare (ignore spec))
  (%unkernel0-pending "run-sandboxed (session)"))

(defmethod sc:run-sandboxed ((backend unkernel-backend) spec)
  "Open a session for SPEC, run its :COMMAND (as on a session), close it — also on a
non-local exit and after a timeout."
  (declare (ignore spec))
  (%unkernel0-pending "run-sandboxed (backend)"))

(defmethod sc:close-sandbox ((session unkernel-session))
  "→ T the first time on an open session, else NIL (closed, or killed by a timeout). Closes
the forwards, calls session.close (the guest powers off), waits up to 5 s for the host to
exit and kills it after that, deletes the private temp dir. State :CLOSED."
  (%unkernel0-pending "close-sandbox"))

(defun forward-port (session guest-port &key (local-port 0))
  "Bridge 127.0.0.1:LOCAL-PORT on the host (0 → an ephemeral port) to GUEST-PORT on the
guest's loopback, over vsock (the only inbound path). → the local port. Each accepted
connection is a new vm.connect(GUEST-PORT). A closed session → UNKERNEL-SESSION-CLOSED."
  (declare (ignore session guest-port local-port))
  (%unkernel0-pending "forward-port"))

(defun close-forward (session local-port)
  "Stop the forward on LOCAL-PORT. → T when it was open, else NIL."
  (declare (ignore session local-port))
  (%unkernel0-pending "close-forward"))
