(in-package #:compute-backend-unkernel)

;;; Sessions: one Node host process = one kernel = one session.
;;;
;;; Given (contract): the class and its readers, UNKERNEL-SESSION-ALIVE-P.
;;; Implemented (R4h-4a): OPEN-SANDBOX, SESSION-EXEC, RUN-SANDBOXED (backend and
;;; session), CLOSE-SANDBOX, FORWARD-PORT, CLOSE-FORWARD, UNKERNEL-SESSION-PID.
;;;
;;; The Lisp side owns every deadline and every teardown. A wall-clock is the
;;; :TIMEOUT of the session.exec call itself (rpc-backend-stdio's STDIO-RPC-TIMEOUT);
;;; the host is never trusted to stop. Every way a session ends goes through
;;; %CLAIM (:OPEN → :CLOSED or :KILLED, exactly once, under the session lock) and
;;; then %RELEASE (the transport closed — the host killed at once for a kill, after
;;; 5 s for a close —, the forwards forgotten, the private temp dir deleted). The
;;; lock is never held across an RPC call or a transport close.

(defclass unkernel-session (sc:sandbox-session)
  ((plan :initarg :plan :reader unkernel-session-plan
         :documentation "The UNKERNEL-PLAN the kernel was booted with (with its TMP).")
   (state :initform :open :accessor %session-state
          :documentation ":OPEN, :CLOSED (CLOSE-SANDBOX) or :KILLED (a timeout or a host failure).")
   (boot-ms :initform nil :accessor %session-boot-ms)
   (forwards :initform '() :accessor %session-forwards
             :documentation "Open forwards: (local-port . guest-port), newest first.")
   (transport :initarg :transport :reader %session-transport
              :documentation "The rpc-backend-stdio client whose child is the host process.")
   (pid :initform nil :accessor %session-pid
        :documentation "The host process's pid, recorded once it was launched.")
   (lock :initform (bt2:make-lock :name "unkernel session") :reader %session-lock
         :documentation "Guards STATE and FORWARDS; never held across an RPC call."))
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
  (or (%session-pid session)
      (%note-pid session)))

(defun %note-pid (session)
  (let ((process (rpc-backend-stdio:stdio-rpc-transport-process (%session-transport session))))
    (when process
      (setf (%session-pid session) (pp:pid process)))))

;;; The private temp dir (compute-protocol's idiom: its helpers are internal,
;;; egao1980/compute-protocol#11).

(defun %make-private-tmp ()
  "A fresh stack-compute-<16 lowercase hex>/ (mode 700) under the physical system temp dir."
  (let ((base (uiop:ensure-directory-pathname
               (sc:physical-path (uiop:ensure-directory-pathname (uiop:temporary-directory)))))
        (state (make-random-state t)))
    (loop
      (let ((dir (merge-pathnames
                  (format nil "stack-compute-~(~16,'0x~)/" (random (expt 16 16) state))
                  base)))
        (unless (uiop:directory-exists-p dir)
          (multiple-value-bind (path created)
              #+sbcl (ensure-directories-exist dir :mode #o700)
              #-sbcl (ensure-directories-exist dir)
            (declare (ignore path))
            (when created
              (return (uiop:ensure-directory-pathname (truename dir))))))))))

(defun %private-tmp-p (pathname)
  (let ((name (car (last (pathname-directory pathname)))))
    (and (stringp name) (uiop:string-prefix-p "stack-compute-" name))))

(defun %delete-tmp (tmp)
  "Delete the private temp dir TMP (a namestring or pathname, or NIL). The tree is
deleted without following symlinks (the guest, as root, may plant some through 9p). A
tree that cannot be deleted is a warning: the session is gone either way."
  (when tmp
    (let ((dir (uiop:ensure-directory-pathname
                (if (stringp tmp) (uiop:parse-native-namestring tmp) tmp))))
      (handler-case
          (uiop:delete-directory-tree dir :validate #'%private-tmp-p :if-does-not-exist :ignore)
        (file-error (e)
          (warn "compute-backend-unkernel: could not delete the private temp dir ~a: ~a"
                (uiop:native-namestring dir) e))))))

;;; The one teardown path.

(defun %claim (session new-state)
  "Move SESSION from :OPEN to NEW-STATE. → T for the one caller that did it, else NIL."
  (bt2:with-lock-held ((%session-lock session))
    (when (eq (%session-state session) :open)
      (setf (%session-state session) new-state)
      t)))

(defun %release (session &key force)
  "Close the transport (FORCE: kill the host at once; else close its stdin, wait 5 s,
then kill it), forget the forwards (their listeners died with the host), delete the
private temp dir. Call after a successful %CLAIM, with no lock held."
  (unwind-protect
       (progn
         (unkernel-session-pid session)
         (rpc-backend-stdio:close-stdio-rpc-transport (%session-transport session)
                                                      :force force :timeout 5))
    (bt2:with-lock-held ((%session-lock session))
      (setf (%session-forwards session) '()))
    (%delete-tmp (plan-tmp (unkernel-session-plan session)))))

(defun %kill-session (session)
  "Kill SESSION (host process, forwards, temp dir); state :KILLED. Idempotent."
  (when (%claim session :killed)
    (%release session :force t)))

(defun %ensure-open (session)
  (unless (unkernel-session-alive-p session)
    (error 'unkernel-session-closed
           :session session
           :message (format nil "it was ~(~a~)" (%session-state session)))))

(defun %call (session method params &key timeout (kill-on-error t))
  "RPC-CALL METHOD on SESSION's host → the result. Every failure kills the session first
\(with no lock held) and then signals: TIMEOUT passed → the STDIO-RPC-TIMEOUT itself; the
host gone → UNKERNEL-ERROR; an error answer → UNKERNEL-ERROR with its code and data
\(the session is kept when KILL-ON-ERROR is NIL and the host is still there)."
  (handler-case
      (rpc-protocol:rpc-call method params :transport (%session-transport session) :timeout timeout)
    (rpc-backend-stdio:stdio-rpc-timeout (e)
      (%kill-session session)
      (error e))
    (rpc-backend-stdio:stdio-rpc-peer-closed (e)
      (%kill-session session)
      (error 'unkernel-error :code (rpc-protocol:rpc-error-code e)
                             :data (rpc-protocol:rpc-error-data e)
                             :message (format nil "the host process died during ~a (~a); the session is closed"
                                              method (rpc-protocol:rpc-error-message e))))
    (rpc-protocol:rpc-error (e)
      (when kill-on-error
        (%kill-session session))
      (error 'unkernel-error :code (rpc-protocol:rpc-error-code e)
                             :data (rpc-protocol:rpc-error-data e)
                             :message (format nil "~a: ~a~:[~;; the session is closed~]"
                                              method (rpc-protocol:rpc-error-message e)
                                              kill-on-error)))))

;;; Open

(defmethod sc:open-sandbox ((backend unkernel-backend) spec)
  "→ an UNKERNEL-SESSION. In order, nothing created before the step that needs it:
CONFINEMENT-AVAILABLE-P (else CONFINEMENT-UNAVAILABLE with its reason); PLAN-SESSION
dry (its refusals); the private temp dir (a fresh stack-compute-<16 hex>/ under the
physical system temp dir, when the confinement's :TMP is :PRIVATE); the plan with it;
the host process (HOST-COMMAND, through rpc-backend-stdio :COMMAND); session.open with
PLAN-REQUEST, waiting UNKERNEL-BACKEND-BOOT-TIMEOUT seconds. A failure after the temp dir
exists kills the host and deletes the temp dir, then signals (a boot failure or a host
error → UNKERNEL-ERROR)."
  (let ((spec (sc:coerce-sandbox-spec spec)))
    (multiple-value-bind (available reason) (sc:confinement-available-p backend)
      (unless available
        (error 'sc:confinement-unavailable :backend backend :reason reason)))
    (plan-session backend spec)           ; every refusal, before anything exists
    (let ((tmp (and (eq (%plan-tmp-mode spec) :private) (%make-private-tmp)))
          (session nil)
          (done nil))
      (unwind-protect
           (let* ((plan (plan-session backend spec :tmp tmp))
                  (s (make-instance 'unkernel-session
                                    :backend backend :spec spec :plan plan
                                    :transport (%host-transport backend))))
             (setf session s)
             (let* ((timeout (unkernel-backend-boot-timeout backend))
                    (result (handler-case (%call s "session.open" (plan-request plan) :timeout timeout)
                              (rpc-backend-stdio:stdio-rpc-timeout ()
                                (error 'unkernel-error
                                       :message (format nil "the kernel did not boot within ~a s" timeout)))))
                    (boot-ms (%json-get result "bootMs")))
               (%note-pid s)
               (setf (%session-boot-ms s) (if (realp boot-ms) (max 1 (round boot-ms)) nil)
                     done t)
               s))
        (unless done
          (if session
              (%kill-session session)
              (%delete-tmp tmp)))))))

;;; Exec

(defun %guest-env (plan env)
  "The environment session.exec sends: PLAN-ENV, then ENV (it wins), as an EQUAL
hash-table of strings. TMPDIR is given without its trailing / (as $TMPDIR usually is)."
  (let ((table (make-hash-table :test 'equal)))
    (loop for (name . value) in (plan-env plan)
          do (setf (gethash name table) value))
    (loop for (name . value) in env
          for key = (%env-name name)
          for v = (%env-value value)
          do (if v (setf (gethash key table) v) (remhash key table)))
    (let ((tmpdir (gethash "TMPDIR" table)))
      (when (and (stringp tmpdir) (> (length tmpdir) 1) (%directory-ns-p tmpdir))
        (setf (gethash "TMPDIR" table) (string-right-trim "/" tmpdir))))
    table))

(defun %exit-code (result)
  (let ((code (%json-get result "exitCode"))
        (signo (%json-get result "signal")))
    (cond ((integerp code) code)
          ((integerp signo) (+ 128 signo))
          (t (error 'unkernel-error :message (format nil "session.exec answered no exit status: ~s" result))))))

(defun %json-string (result key)
  (let ((v (%json-get result key)))
    (if (stringp v) v "")))

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
  (check-type argv cons)
  (check-type input (or null string))
  (check-type wall-clock (or null (real (0))))
  (%ensure-open session)
  (let* ((plan (unkernel-session-plan session))
         (params (list (cons "argv" (map 'vector (lambda (a) (if (stringp a) a (princ-to-string a))) argv))
                       (cons "cwd" (cond ((null directory) (plan-directory plan))
                                         ((pathnamep directory) (uiop:native-namestring directory))
                                         (t directory)))
                       (cons "env" (%guest-env plan env))
                       (cons "input" (or input ""))
                       (cons "timeoutMs" (if wall-clock (ceiling (* 1000 wall-clock)) :null))))
         (result (handler-case (%call session "session.exec" params :timeout wall-clock)
                   ;; %CALL killed the session already: the host, forwards and tmp are gone.
                   (rpc-backend-stdio:stdio-rpc-timeout () :timeout))))
    (if (eq result :timeout)
        (restart-case
            (error 'sc:sandbox-timeout
                   :limit wall-clock
                   :message (format nil "~{~a~^ ~}: the session was killed (host process, kernel, forwards, private temp dir)"
                                    argv))
          (sc:abort-execution ()
            :report "Give up this execution and return NIL (the session is dead)."
            nil))
        (values (%exit-code result)
                (%json-string result "stdout")
                (%json-string result "stderr")))))

;;; run-sandboxed

(defmethod sc:run-sandboxed ((session unkernel-session) spec)
  "SPEC NIL → the session spec's :COMMAND. Otherwise SPEC's :COMMAND with its :ENV and
:WALL-CLOCK; its :CONFINEMENT, :MOUNTS and :NETWORK must be absent (NIL, NIL, :NONE) or
equal to the session spec's, else COMPUTE-ERROR (mounts and network are fixed at open);
:CODE → SANDBOX-DENIED :policy :lisp; no command → COMPUTE-ERROR. → a SANDBOX-RESULT
\(exit code, stdout, stderr, the spec's :ARTIFACTS), or NIL after ABORT-EXECUTION."
  (%ensure-open session)
  (let* ((own (sc:sandbox-session-spec session))
         (given (and spec (sc:coerce-sandbox-spec spec)))
         (run (or given own)))
    (when (sc:sandbox-spec-code run)
      (error 'sc:sandbox-denied :spec run :policy :lisp
                                :message "compute-backend-unkernel 0.1.0 runs :command only"))
    (when (sc:sandbox-spec-cpu-limit run)
      (error 'sc:sandbox-denied :spec run :policy :cpu-limit
                                :message "the unkernel guest has no CPU limit"))
    (when given
      (flet ((fixed (what given-value own-value absent)
               (unless (or (equal given-value absent) (equal given-value own-value))
                 (error 'sc:compute-error
                        :spec run
                        :message (format nil "~a is fixed when the session opens: open another session for ~s"
                                         what given-value)))))
        (fixed ":confinement" (sc:sandbox-spec-confinement given) (sc:sandbox-spec-confinement own) nil)
        (fixed ":mounts" (sc:sandbox-spec-mounts given) (sc:sandbox-spec-mounts own) nil)
        (fixed ":network" (sc:sandbox-spec-network given) (sc:sandbox-spec-network own) :none)))
    (let ((command (sc:sandbox-spec-command run)))
      (unless command
        (error 'sc:compute-error :spec run :message "sandbox-spec needs :command"))
      (multiple-value-bind (code out err)
          (session-exec session command
                        :env (and given (sc:sandbox-spec-env given))
                        :wall-clock (sc:sandbox-spec-wall-clock run))
        (and code
             (sc:make-sandbox-result :exit-code code :stdout out :stderr err
                                     :artifacts (sc:sandbox-spec-artifacts run)))))))

(defmethod sc:run-sandboxed ((backend unkernel-backend) spec)
  "Open a session for SPEC, run its :COMMAND (as on a session), close it — also on a
non-local exit and after a timeout."
  (let ((session (sc:open-sandbox backend (sc:coerce-sandbox-spec spec))))
    (unwind-protect (sc:run-sandboxed session nil)
      (sc:close-sandbox session))))

;;; Close

(defmethod sc:close-sandbox ((session unkernel-session))
  "→ T the first time on an open session, else NIL (closed, or killed by a timeout). Closes
the forwards, calls session.close (the guest powers off), waits up to 5 s for the host to
exit and kills it after that, deletes the private temp dir. State :CLOSED."
  (when (%claim session :closed)
    (unwind-protect
         ;; The host closes its forwards and powers the guest off. Whatever it answers,
         ;; or if it is already gone, the teardown below runs the same.
         (handler-case (rpc-protocol:rpc-call "session.close" nil
                                              :transport (%session-transport session)
                                              :timeout 15)
           (rpc-protocol:rpc-error () nil))
      (%release session))
    t))

;;; Forwards

(defun forward-port (session guest-port &key (local-port 0))
  "Bridge 127.0.0.1:LOCAL-PORT on the host (0 → an ephemeral port) to GUEST-PORT on the
guest's loopback, over vsock (the only inbound path). → the local port. Each accepted
connection is a new vm.connect(GUEST-PORT). A closed session → UNKERNEL-SESSION-CLOSED."
  (check-type guest-port (integer 1 65535))
  (check-type local-port (integer 0 65535))
  (%ensure-open session)
  (let* ((result (%call session "session.forward"
                        (list (cons "guestPort" guest-port) (cons "localPort" local-port))
                        :timeout 30 :kill-on-error nil))
         (port (%json-get result "localPort")))
    (unless (typep port '(integer 1 65535))
      (error 'unkernel-error :message (format nil "session.forward answered no port: ~s" result)))
    (bt2:with-lock-held ((%session-lock session))
      (push (cons port guest-port) (%session-forwards session)))
    port))

(defun close-forward (session local-port)
  "Stop the forward on LOCAL-PORT. → T when it was open, else NIL."
  (let ((entry (bt2:with-lock-held ((%session-lock session))
                 (assoc local-port (%session-forwards session)))))
    (when (and entry (unkernel-session-alive-p session))
      (%call session "session.unforward" (list (cons "localPort" local-port))
             :timeout 30 :kill-on-error nil)
      (bt2:with-lock-held ((%session-lock session))
        (setf (%session-forwards session) (remove entry (%session-forwards session))))
      t)))
