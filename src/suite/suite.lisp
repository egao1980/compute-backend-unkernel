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
;;; Stubbed: the CONFINEMENT-PROBE method.

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

(defmethod suite:confinement-probe ((backend uk:unkernel-backend) confinement ops &key directory)
  (declare (ignore confinement ops directory))
  (uk::%unkernel0-pending "confinement-probe (the session adapter)"))
