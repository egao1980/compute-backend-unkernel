(in-package #:compute-backend-unkernel/tests)

;;; Fail closed: no Node (or too old a Node, or no setup) → CONFINEMENT-UNAVAILABLE,
;;; before anything is created. Every OS; the fake-Node rows need a POSIX shell.

(defparameter +missing-node+ "/nonexistent/bin/node")

(defun missing-node-backend ()
  (make-unkernel-backend :node +missing-node+))

(defun fake-node (dir version)
  "An executable script in DIR printing VERSION, standing in for node."
  (let ((path (merge-pathnames "fake-node" dir)))
    (write-text path (format nil "#!/bin/sh~%echo ~a~%" version))
    (pp:run (list "chmod" "+x" (uiop:native-namestring path)) :output :string :error-output :string)
    (uiop:native-namestring path)))

(defun reason-of (backend)
  (multiple-value-bind (ok reason) (sc:confinement-available-p backend)
    (values ok reason)))

(deftest availability-backend-defaults
  (let ((b (make-unkernel-backend)))
    (ok (unkernel-backend-p b))
    (ok (typep b 'sc:confining-backend))
    (ok (= +default-memory-mib+ (unkernel-backend-memory-mib b)))
    (ok (= 120 (unkernel-backend-boot-timeout b)))
    (ok (equal (default-unkernel-home) (unkernel-backend-home b)))
    (ok (stringp (unkernel-backend-node b))))
  (let ((b (make-unkernel-backend :node "/opt/node/bin/node" :home "/srv/uk" :memory-mib 512)))
    (ok (equal "/opt/node/bin/node" (unkernel-backend-node b)))
    (ok (equal #p"/srv/uk/" (unkernel-backend-home b)) "HOME is a directory pathname")
    (ok (= 512 (unkernel-backend-memory-mib b)))
    (ok (equal (list "/opt/node/bin/node" (uiop:native-namestring (host-script-pathname))
                     "--home" (uiop:native-namestring #p"/srv/uk/"))
               (host-command b)))))

(deftest availability-node-env-variable
  (let ((old (uiop:getenv "COMPUTE_UNKERNEL_NODE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "COMPUTE_UNKERNEL_NODE") "/env/node")
           (ok (equal "/env/node" (unkernel-backend-node (make-unkernel-backend))))
           (ok (equal "/given/node" (unkernel-backend-node (make-unkernel-backend :node "/given/node")))
               ":node wins over the variable")
           (setf (uiop:getenv "COMPUTE_UNKERNEL_NODE") "")
           (ok (equal "node" (unkernel-backend-node (make-unkernel-backend))) "else node on PATH"))
      (setf (uiop:getenv "COMPUTE_UNKERNEL_NODE") (or old "")))))

(deftest availability-probe-node-missing
  (multiple-value-bind (major reason) (probe-node +missing-node+)
    (ok (null major))
    (ok (and (stringp reason) (search +missing-node+ reason)) "the reason names the executable")
    (ok (search "Node 24" reason))))

(deftest availability-node-missing
  (multiple-value-bind (ok reason) (reason-of (missing-node-backend))
    (ok (null ok) "no Node → unavailable, never an unconfined run")
    (ok (stringp reason))
    (if (windows-p)
        (ok (search "Windows" reason) "Windows is refused first")
        (progn (ok (search +missing-node+ reason))
               (ok (search "Node 24" reason))))))

(deftest availability-probed-once
  (let ((b (missing-node-backend)))
    (multiple-value-bind (ok1 r1) (sc:confinement-available-p b)
      (multiple-value-bind (ok2 r2) (sc:confinement-available-p b)
        (ok (and (null ok1) (null ok2)))
        (ok (eq r1 r2) "the cached reason, not a second probe")))))

(deftest availability-open-fails-closed
  (let ((before (stack-compute-dirs))
        (b (missing-node-backend)))
    (with-tree (root area ro outside)
      (let ((c (handler-case (progn (sc:open-sandbox b (area-spec area)) nil)
                 (sc:confinement-unavailable (c) c))))
        (ok c "OPEN-SANDBOX → CONFINEMENT-UNAVAILABLE")
        (ok (and c (eq b (sc:confinement-unavailable-backend c))))
        (ok (and c (stringp (sc:confinement-unavailable-reason c))))))
    (ok (equal before (stack-compute-dirs)) "no private temp dir was created")))

(deftest availability-run-fails-closed
  (ok (signals (sc:run-sandboxed (missing-node-backend) '("true")) 'sc:confinement-unavailable))
  (ok (signals (sc:run-sandboxed (missing-node-backend)
                                 (sc:make-sandbox-spec :command '("true") :network :allow))
               'sc:confinement-unavailable))
  (ok (signals (sc:with-sandbox (s (missing-node-backend) '("true")) s) 'sc:confinement-unavailable)))

(deftest availability-check-confinement
  (ok (signals (sc:check-confinement (missing-node-backend)
                                     (sc:make-confinement :read :system :deny-read '()))
               'sc:confinement-unavailable)
      "compute-protocol's own check refuses it too"))

(deftest availability-not-a-command-prefix
  (ok (signals (sc:backend-confine-argv (make-unkernel-backend) nil '("true") nil nil)
               'sc:compute-error)
      "a session backend: no per-command launch"))

(deftest availability-node-too-old
  (if (windows-p)
      (skip "a POSIX shell script stands in for node")
      (with-tree (root area ro outside)
        (let ((old (fake-node root "v20.11.1")))
          (multiple-value-bind (major reason) (probe-node old)
            (ok (null major))
            (ok (and (stringp reason) (search "v20.11.1" reason)))
            (ok (search "Node 24" reason)))
          (multiple-value-bind (ok reason) (reason-of (make-unkernel-backend :node old))
            (ok (null ok))
            (ok (search "Node 24" reason)))))))

(deftest availability-node-garbage
  (if (windows-p)
      (skip "a POSIX shell script stands in for node")
      (with-tree (root area ro outside)
        (multiple-value-bind (major reason) (probe-node (fake-node root "not-a-version"))
          (ok (null major) "a program that does not print vN.N.N is not Node")
          (ok (stringp reason))))))

(deftest availability-probe-node-real
  (if (windows-p)
      (skip "Windows hosts are not supported (0.1.0)")
      (with-tree (root area ro outside)
        (multiple-value-bind (major version) (probe-node (fake-node root "v26.12.1"))
          (ok (eql 26 major))
          (ok (equal "v26.12.1" version))))))

(deftest availability-home-not-set-up
  ;; Node 24+ but an empty HOME: the reason names scripts/setup.sh. Needs a real Node.
  (if (windows-p)
      (skip "Windows hosts are not supported (0.1.0)")
      (let ((probe (make-unkernel-backend)))
        (if (not (probe-node (unkernel-backend-node probe)))
            (if (ci-strict-p)
                (ok nil "COMPUTE_UNKERNEL_CI: Node 24+ must be on PATH")
                (skip (format nil "no Node 24+ here: ~a" (nth-value 1 (probe-node (unkernel-backend-node probe))))))
            (with-tree (root area ro outside)
              (let ((b (make-unkernel-backend :home (merge-pathnames "empty-home/" root))))
                (multiple-value-bind (ok reason) (sc:confinement-available-p b)
                  (ok (null ok))
                  (ok (and (stringp reason) (search "scripts/setup.sh" reason))))
                (ok (signals (host-check b) 'sc:confinement-unavailable))
                (ok (signals (sc:open-sandbox b '("true")) 'sc:confinement-unavailable))))))))

(deftest availability-windows
  (if (windows-p)
      (multiple-value-bind (ok reason) (sc:confinement-available-p (make-unkernel-backend))
        (ok (null ok))
        (ok (search "Windows" reason)))
      (skip "Windows only")))
