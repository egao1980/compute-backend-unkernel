(in-package #:compute-backend-unkernel/tests)

;;; The pins (the version-pin exception: exact, and checked). Every OS reads the
;;; shipped host files; the live tests check what actually runs.

(defun host-json (name)
  (json:decode (uiop:read-file-string (merge-pathnames name (host-directory))
                                      :external-format :utf-8)))

(defun keys-of (table)
  (sort (loop for k being the hash-keys of table collect k) #'string<))

(deftest pins-constants
  (ok (equal "0.2.0-261121-e69adda" +unkernel-version+))
  (ok (equal "sha512-RcN062gFjX73dIDStLzu8aSVbMhn3+GhSARIeVo2z2+FNo4+jtpvK8MNEmirr7TO9y05V/jIT2tZmu35wkqbcA=="
             +unkernel-integrity+))
  (ok (equal "https://registry.npmjs.org/unkernel/-/unkernel-0.2.0-261121-e69adda.tgz"
             +unkernel-tarball+))
  (ok (equal "alpine-3.24.4-e0d59c37c0882d76" +alpine-image+))
  (ok (equal "02460df31c14772659bb347a651693ac9aaa7a8c2477f05e4e5e4d5c756dd567" +alpine-sha256+))
  (ok (equal '("sbcl=2.6.5-r0") +guest-packages+))
  (ok (eql 24 +node-min-major+))
  (ok (equal '(1024 256 2048) (list +default-memory-mib+ +min-memory-mib+ +max-memory-mib+)))
  (ok (equal "/home/user/" +guest-home+))
  (ok (eql 1020 +host-command-port+))
  (ok (eq :microvm +unkernel-placement+) "H4f placement: a guest kernel attached over vsock"))

(deftest pins-features
  (ok (equal '(:filesystem :read-system :network-none :network-allow :memory-limit)
             +unkernel-features+))
  (ok (equal +unkernel-features+ (sc:confinement-features (make-unkernel-backend))))
  (ok (subsetp +unkernel-features+ sc:+confinement-features+))
  (ok (not (sc:confinement-supports-p (make-unkernel-backend) :deny-read))
      "the guest sees only its mounts: no read-all to subtract from"))

(deftest pins-host-package-json
  (let ((pkg (host-json "package.json")))
    (ok (hash-table-p pkg))
    (ok (eq t (gethash "private" pkg)))
    (ok (equal "module" (gethash "type" pkg)))
    (let ((deps (gethash "dependencies" pkg)))
      (ok (equal '("unkernel") (keys-of deps)) "unkernel is the only dependency")
      (ok (equal +unkernel-version+ (gethash "unkernel" deps))
          "exact: no ^ or ~ range"))
    (ok (null (nth-value 1 (gethash "devDependencies" pkg))))
    (ok (null (nth-value 1 (gethash "optionalDependencies" pkg))))
    (ok (null (nth-value 1 (gethash "scripts" pkg))) "no install scripts of our own")))

(deftest pins-host-lockfile
  (let* ((lock (host-json "package-lock.json"))
         (packages (gethash "packages" lock))
         (root (gethash "" packages))
         (entry (gethash "node_modules/unkernel" packages)))
    (ok (eql 3 (gethash "lockfileVersion" lock)))
    (ok (equal '("" "node_modules/unkernel") (keys-of packages))
        "nothing but the root and unkernel (no transitive deps)")
    (ok (equal +unkernel-version+ (gethash "unkernel" (gethash "dependencies" root))))
    (ok (equal +unkernel-version+ (gethash "version" entry)))
    (ok (equal +unkernel-tarball+ (gethash "resolved" entry)))
    (ok (equal +unkernel-integrity+ (gethash "integrity" entry)))))

(deftest pins-shipped-files
  (ok (uiop:file-exists-p (host-script-pathname)))
  (ok (uiop:subpathp (host-script-pathname) (host-directory)))
  (ok (equal "unkernel-host.mjs" (file-namestring (host-script-pathname))))
  (ok (uiop:file-exists-p (setup-script-pathname)))
  (ok (equal "setup.sh" (file-namestring (setup-script-pathname)))))

(deftest pins-default-home
  (let ((old (uiop:getenv "COMPUTE_UNKERNEL_HOME")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "COMPUTE_UNKERNEL_HOME") "")
           (let ((home (uiop:native-namestring (default-unkernel-home))))
             (ok (search (format nil "compute-backend-unkernel/~a/" +unkernel-version+)
                         (substitute #\/ #\\ home))
                 "the default is versioned: a bump never reuses an old setup"))
           (setf (uiop:getenv "COMPUTE_UNKERNEL_HOME") (uiop:native-namestring (uiop:temporary-directory)))
           (ok (equal (uiop:ensure-directory-pathname (uiop:temporary-directory))
                      (default-unkernel-home))))
      (setf (uiop:getenv "COMPUTE_UNKERNEL_HOME") (or old "")))))

(deflive pins-host-check (backend)
  (let ((info (host-check backend)))
    (ok (equal +unkernel-version+ (getf info :unkernel)) "the installed unkernel is the pin")
    (ok (equal +alpine-sha256+ (getf info :distro-sha256)))
    (ok (equal +unkernel-version+ (getf info :guest-unkernel)) "the guest disk was built for it")
    (ok (equal +alpine-image+ (getf info :guest-image)))
    (ok (equal +guest-packages+ (getf info :guest-packages)))
    (let ((node (getf info :node)))
      (ok (and (stringp node) (char= #\v (char node 0))))
      (ok (>= (parse-integer node :start 1 :junk-allowed t) +node-min-major+)))))

(deflive pins-guest-versions (backend)
  (with-session (s backend nil)
    (ok (equal "3.24.4" (sh-out s "cat /etc/alpine-release")))
    (ok (equal "aarch64" (sh-out s "uname -m")))
    (ok (uiop:string-prefix-p "SBCL 2.6.5" (sh-out s "sbcl --version")))))
