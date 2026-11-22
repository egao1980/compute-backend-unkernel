(in-package #:compute-backend-unkernel/tests)

;;; Test support. Three kinds of test:
;;;   every OS (DEFTEST)    the pins, availability refusals
;;;   Unix, pure (DEFUNIX)  planning (Unix paths); Windows skips with a note
;;;   live (DEFLIVE)        a real kernel. Needs SBCL (sb-bsd-sockets), a Unix host and an
;;;                         available backend (Node 24+, HOME set up by scripts/setup.sh).
;;;                         Unavailable → one SKIP with the reason; under
;;;                         COMPUTE_UNKERNEL_CI (the repo's `unkernel` CI job) a failure
;;;                         instead: that job proves the backend, it must not skip it.

(defun windows-p () (uiop:os-windows-p))

(defun ci-strict-p ()
  (let ((v (uiop:getenv "COMPUTE_UNKERNEL_CI")))
    (and v (plusp (length v)) (string/= v "0"))))

(defmacro defunix (name &body body)
  "A DEFTEST on Unix; on Windows one SKIP."
  `(deftest ,name
     (if (windows-p)
         (skip "planning tests use Unix paths: skipped on Windows")
         (progn ,@body))))

(defvar *live-backend* nil
  "The backend every live test shares (default node and home; availability probed once).")

(defun live-backend ()
  "The shared live backend, or NIL after one SKIP (or, under COMPUTE_UNKERNEL_CI, one
failing assertion) carrying the availability reason."
  (unless *live-backend*
    (setf *live-backend* (make-unkernel-backend)))
  (multiple-value-bind (ok reason) (sc:confinement-available-p *live-backend*)
    (cond (ok *live-backend*)
          ((ci-strict-p)
           (ok nil (format nil "COMPUTE_UNKERNEL_CI: the backend must be available here: ~a" reason))
           nil)
          (t (skip (format nil "unkernel unavailable here: ~a" reason))
             nil))))

(defmacro deflive (name (backend) &body body)
  "A DEFTEST whose BODY runs with BACKEND bound to the live backend; else one SKIP."
  `(deftest ,name
     (cond ((windows-p) (skip "Windows hosts are not supported (0.1.0)"))
           ((not (member :sbcl *features*)) (skip "live tests need SBCL (sb-bsd-sockets)"))
           (t (let ((,backend (live-backend)))
                (when ,backend ,@body))))))

;;; Paths and trees

(defun random-hex ()
  (format nil "~(~8,'0x~)" (random (expt 16 8) (make-random-state t))))

(defun ns (p)
  "Native namestring of the physical path (directories end in /)."
  (uiop:native-namestring (sc:physical-path p)))

(defun write-text (path text)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede :if-does-not-exist :create
                          :external-format :utf-8)
    (write-string text s))
  path)

(defun read-text (path)
  (and (uiop:file-exists-p path)
       (uiop:read-file-string path :external-format :utf-8)))

(defun rm-rf (dir)
  "Delete DIR's tree without following symlinks (tests make links that point out of it)."
  (when (uiop:directory-exists-p dir)
    (if (windows-p)
        (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)
        (pp:run (list "rm" "-rf" (uiop:native-namestring dir)) :output :string :error-output :string))))

(defun call-with-tree (fn)
  "FN on (root area ro outside), a fresh physical temp tree: area/f = \"f\",
ro/r = \"readonly\", outside/victim = \"original\". Deleted after."
  (let* ((base (sc:physical-path (uiop:ensure-directory-pathname (uiop:temporary-directory))))
         (root (ensure-directories-exist
                (merge-pathnames (format nil "unkernel-test-~a/" (random-hex)) base))))
    (unwind-protect
         (flet ((sub (name) (ensure-directories-exist (merge-pathnames name root))))
           (let ((area (sub "area/")) (ro (sub "ro/")) (outside (sub "outside/")))
             (write-text (merge-pathnames "f" area) "f")
             (write-text (merge-pathnames "r" ro) "readonly")
             (write-text (merge-pathnames "victim" outside) "original")
             (funcall fn root area ro outside)))
      (rm-rf root))))

(defmacro with-tree ((root area ro outside) &body body)
  `(call-with-tree (lambda (,root ,area ,ro ,outside)
                     (declare (ignorable ,root ,area ,ro ,outside))
                     ,@body)))

(defun area-confinement (area &key readable (network :none) env (tmp :private) memory-limit)
  "The usual session confinement: AREA writable, READABLE read-only, :read :system."
  (sc:make-confinement :writable (list area) :readable readable :read :system
                       :deny-read '() :network network :env env :tmp tmp
                       :memory-limit memory-limit))

(defun area-spec (area &rest keys &key readable network env tmp memory-limit &allow-other-keys)
  "A sandbox spec with AREA-CONFINEMENT; other KEYS go to MAKE-SANDBOX-SPEC."
  (let ((spec-keys (loop for (k v) on keys by #'cddr
                         unless (member k '(:readable :network :env :tmp :memory-limit))
                           append (list k v))))
    (apply #'sc:make-sandbox-spec
           :confinement (area-confinement area :readable readable
                                               :network (or network :none)
                                               :env env :tmp (or tmp :private)
                                               :memory-limit memory-limit)
           spec-keys)))

(defmacro with-session ((var backend spec) &body body)
  `(let ((,var (sc:open-sandbox ,backend ,spec)))
     (unwind-protect (progn ,@body)
       (sc:close-sandbox ,var))))

(defun sh (session script &rest keys)
  "SESSION-EXEC of sh -c SCRIPT → (values exit-code stdout stderr)."
  (apply #'session-exec session (list "sh" "-c" script) keys))

(defun sh-out (session script &rest keys)
  "stdout of SH, trimmed."
  (string-trim '(#\Space #\Newline #\Return #\Tab)
               (nth-value 1 (apply #'sh session script keys))))

(defun pid-alive-p (pid)
  (eql 0 (pp:run (list "kill" "-0" (princ-to-string pid)) :output :string :error-output :string)))

(defun wait-until (fn seconds)
  "Poll FN every 0.1 s for SECONDS → T as soon as it is true, else NIL."
  (loop repeat (ceiling (* 10 seconds))
        when (funcall fn) return t
        do (sleep 0.1)
        finally (return (and (funcall fn) t))))

(defun stack-compute-dirs ()
  "The stack-compute-* directories in the physical system temp dir (native namestrings)."
  (let ((base (sc:physical-path (uiop:ensure-directory-pathname (uiop:temporary-directory)))))
    (sort (loop for d in (uiop:subdirectories base)
                for name = (car (last (pathname-directory d)))
                when (and (stringp name) (uiop:string-prefix-p "stack-compute-" name))
                  collect (uiop:native-namestring d))
          #'string<)))

(defun mount-at (plan guest)
  "The plan mount whose :GUEST is GUEST, or NIL."
  (find guest (plan-mounts plan) :key (lambda (m) (getf m :guest)) :test #'equal))

;;; Host-side TCP (SBCL)

(defun open-listener ()
  "A TCP socket listening on 127.0.0.1 (ephemeral port), backlog only. → (values socket port)."
  #+sbcl
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen socket 16)
    (values socket (nth-value 1 (sb-bsd-sockets:socket-name socket))))
  #-sbcl (error "open-listener: SBCL only"))

(defun close-socket (socket)
  #+sbcl (ignore-errors (sb-bsd-sockets:socket-close socket))
  #-sbcl (declare (ignore socket)))

(defun tcp-connect-p (port)
  "True when a TCP connection to 127.0.0.1:PORT is accepted."
  #+sbcl
  (handler-case
      (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
        (unwind-protect
             (progn (sb-bsd-sockets:socket-connect s #(127 0 0 1) port) t)
          (ignore-errors (sb-bsd-sockets:socket-close s))))
    (error () nil))
  #-sbcl (progn port (error "tcp-connect-p: SBCL only")))

(defun tcp-exchange (port text)
  "Connect to 127.0.0.1:PORT, send TEXT, half-close, read until EOF → the reply string."
  #+sbcl
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream s :input t :output t
                                                              :element-type 'character
                                                              :external-format :utf-8
                                                              :timeout 30)))
             (write-string text stream)
             (finish-output stream)
             (sb-bsd-sockets:socket-shutdown s :direction :output)
             (with-output-to-string (out)
               (loop for line = (read-line stream nil)
                     while line do (write-line line out)))))
      (ignore-errors (sb-bsd-sockets:socket-close s))))
  #-sbcl (progn port text (error "tcp-exchange: SBCL only")))
