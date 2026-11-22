(in-package #:compute-backend-unkernel/tests)

;;; compute-protocol's confinement suite through the session adapter (SBCL, live):
;;; every case but :network-allow; with the :read :system base :secret-read and
;;; :outside-read-all skip, so 18 laws run and none fails.

(deftest suite-cases-table
  (ok (equal '(:network-allow) compute-backend-unkernel/suite:+unkernel-suite-excluded+))
  (let ((cases (compute-backend-unkernel/suite:unkernel-suite-cases)))
    (ok (= 20 (length cases)))
    (ok (not (member :network-allow cases)))
    (ok (equal (remove :network-allow (stack-compute-suite:suite-case-names)) cases)
        "suite order kept")))

(deflive suite-through-sessions (backend)
  (multiple-value-bind (failures ran skipped)
      (compute-backend-unkernel/suite:run-unkernel-suite backend)
    (format t "~&;; unkernel suite: ~d ran, ~d skipped ~s~%" (length ran) (length skipped) skipped)
    (dolist (f failures)
      (format t ";;   FAIL ~s: ~a~%" (car f) (cdr f)))
    (ok (null failures) (format nil "~{~s~^, ~}" (mapcar #'car failures)))
    (ok (= 18 (length ran)))
    (ok (equal '(:secret-read :outside-read-all) skipped))))

(deflive suite-probe-runs-in-the-guest (backend)
  (with-tree (root area ro outside)
    (let* ((c (sc:make-confinement :writable (list area)
                                   :readable (list (sc:physical-path (stack-compute-suite:probe-program-pathname)))
                                   :read :system :deny-read '()))
           (results (stack-compute-suite:confinement-probe
                     backend c `((:cwd) (:getenv "TMPDIR") (:write ,(concatenate 'string (ns area) "p.txt") "x")))))
      (ok (= 3 (length results)))
      (ok (equal (list :value (string-right-trim "/" (ns area))) (first results)))
      (ok (and (consp (second results)) (search "stack-compute-" (second (second results)))))
      (ok (eq :ok (third results)))
      (ok (equal "x" (read-text (merge-pathnames "p.txt" area))) "the guest probe wrote the host area"))))

(deftest suite-unavailable-refused
  (ok (signals (compute-backend-unkernel/suite:run-unkernel-suite
                (make-unkernel-backend :node "/nonexistent/bin/node"))
               'sc:confinement-unavailable)))
