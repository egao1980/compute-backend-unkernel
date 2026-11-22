(defpackage #:compute-backend-unkernel/suite
  (:use #:cl)
  (:local-nicknames (#:sc #:compute-protocol)
                    (#:suite #:compute-protocol/confinement-suite)
                    (#:uk #:compute-backend-unkernel))
  (:export #:+unkernel-suite-excluded+
           #:unkernel-suite-cases
           #:run-unkernel-suite))

(in-package #:compute-backend-unkernel/suite)

;;; compute-protocol's confinement suite through an unkernel session: the session
;;; adapter. The suite's default probe confines the HOST's SBCL with CONFINE-COMMAND;
;;; here each probe is one session booted from the case's confinement (PLAN-SESSION
;;; rules: writable read-write, readable read-only, each at its own path, the private
;;; temp dir), running the GUEST's SBCL on the mounted probe program:
;;;   sbcl --script <physical path of SUITE:PROBE-PROGRAM-PATHNAME>
;;; with the printed ops on stdin (SESSION-EXEC :INPUT) and DIRECTORY passed on; the
;;; results READ from stdout (*READ-EVAL* NIL); the session closed before returning, so
;;; the private TMPDIR is gone (the :tmpdir-private law). A probe that does not answer
;;; one result per op → an ERROR naming the exit code and stderr, as the default method.
;;;
;;; Given (contract): the exclusions, UNKERNEL-SUITE-CASES, RUN-UNKERNEL-SUITE.
;;; Implemented (R4h-4a): the CONFINEMENT-PROBE method.

(defparameter +unkernel-suite-excluded+
  '(:network-allow)
  "Suite cases that do not apply: :NETWORK-ALLOW connects to a listener on the HOST's
loopback, which the guest never reaches by design (hostLoopback off).")

(defun unkernel-suite-cases ()
  "SUITE:SUITE-CASE-NAMES minus +UNKERNEL-SUITE-EXCLUDED+, in suite order."
  (remove-if (lambda (name) (member name +unkernel-suite-excluded+))
             (suite:suite-case-names)))

(defun run-unkernel-suite (backend &key root)
  "SUITE:RUN-CONFINEMENT-SUITE on BACKEND with UNKERNEL-SUITE-CASES → (values failures
ran skipped). With the :READ :SYSTEM base, :SECRET-READ and :OUTSIDE-READ-ALL skip."
  (suite:run-confinement-suite backend :cases (unkernel-suite-cases) :root root))

(defparameter *probe-wall-clock* 600
  "Seconds one probe run may take in the guest (its SBCL is ~30x slower than native).")

(defun %print-ops (ops)
  "OPS printed for the probe's stdin, as compute-protocol's default method prints them."
  (with-standard-io-syntax
    (let ((*print-readably* nil))
      (prin1-to-string ops))))

(defun %read-results (text)
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (read-from-string text))))

(defun %probe-spec (confinement)
  "A session spec for CONFINEMENT that has the probe program mounted read-only at its
own path: as one of the confinement's :READABLE entries (the suite's confinement lists
it), else as a spec mount."
  (let* ((program (sc:physical-path (suite:probe-program-pathname)))
         (ns (uiop:native-namestring program))
         (listed (some (lambda (r) (equal ns (uiop:native-namestring (sc:physical-path r))))
                       (sc:confinement-readable confinement))))
    (sc:make-sandbox-spec :confinement confinement
                          :mounts (unless listed (list ns)))))

(defmethod suite:confinement-probe ((backend uk:unkernel-backend) confinement ops &key directory)
  (let ((program (uiop:native-namestring (sc:physical-path (suite:probe-program-pathname))))
        (session (sc:open-sandbox backend (%probe-spec confinement))))
    (multiple-value-bind (code out err)
        (unwind-protect
             (uk:session-exec session (list "sbcl" "--script" program)
                              :input (%print-ops ops)
                              :directory (and directory
                                              (uiop:native-namestring (sc:physical-path directory)))
                              :wall-clock *probe-wall-clock*)
          ;; Closed before the results are judged: the private TMPDIR is gone.
          (sc:close-sandbox session))
      (let ((results (and (eql code 0)
                          (handler-case (%read-results out)
                            ((or reader-error end-of-file) () nil)))))
        (unless (and (listp results) (= (length results) (length ops)))
          (error "confinement probe failed in the unkernel guest (exit ~a): ~a~@[ — stdout ~s~]"
                 code (string-trim '(#\Space #\Newline) (or err ""))
                 (and (eql code 0) out)))
        results))))
