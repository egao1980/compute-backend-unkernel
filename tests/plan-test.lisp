(in-package #:compute-backend-unkernel/tests)

;;; PLAN-SESSION and PLAN-REQUEST: pure, every Unix host (no Node needed).

(defparameter +fake-home+ "/nonexistent-unkernel-home/")

(defun plan-backend (&rest keys)
  (apply #'make-unkernel-backend :home +fake-home+ keys))

(defun tmp-dir (root)
  "A stand-in private temp dir inside ROOT (the plan only needs a directory)."
  (ensure-directories-exist (merge-pathnames "stack-compute-0123456789abcdef/" root)))

(defun plan (spec &key tmp (backend (plan-backend)))
  (plan-session backend spec :tmp tmp))

(defun sorted-by-guest-p (mounts)
  (loop for (a b) on mounts while b
        always (string< (getf a :guest) (getf b :guest))))

(defunix plan-mounts-area-and-readable
  (with-tree (root area ro outside)
    (let* ((tmp (tmp-dir root))
           (p (plan (area-spec area :readable (list ro)) :tmp tmp))
           (mounts (plan-mounts p)))
      (ok (unkernel-plan-p p))
      (ok (= 3 (length mounts)) "area, tmp, ro — nothing else of the host")
      (ok (sorted-by-guest-p mounts) "sorted by guest path")
      (ok (equal (list :guest (ns area) :host (ns area) :read-only nil :kind :directory)
                 (mount-at p (ns area)))
          "the area: read-write, at its own physical path")
      (ok (equal (list :guest (ns tmp) :host (ns tmp) :read-only nil :kind :directory)
                 (mount-at p (ns tmp)))
          "the private temp dir: read-write")
      (ok (equal (list :guest (ns ro) :host (ns ro) :read-only t :kind :directory)
                 (mount-at p (ns ro)))
          "readable: read-only")
      (ok (null (mount-at p (ns outside))))
      (ok (null (mount-at p (ns root)))))))

(defunix plan-readable-file
  (with-tree (root area ro outside)
    (let* ((file (merge-pathnames "r" ro))
           (p (plan (area-spec area :readable (list file)))))
      (ok (equal (list :guest (ns file) :host (ns file) :read-only t :kind :file)
                 (mount-at p (ns file)))
          "a readable file is mounted alone, read-only")
      (ok (null (mount-at p (ns ro))) "not its directory"))))

(defunix plan-spec-mounts-read-only
  (with-tree (root area ro outside)
    (let* ((p (plan (sc:make-sandbox-spec :command '("true")
                                          :mounts (list (namestring ro)
                                                        (list (namestring outside) "/opt/data/")))))
           (same (mount-at p (ns ro)))
           (moved (mount-at p "/opt/data/")))
      (ok (equal (list :guest (ns ro) :host (ns ro) :read-only t :kind :directory) same)
          "a bare path: the same path in the guest")
      (ok (equal (list :guest "/opt/data/" :host (ns outside) :read-only t :kind :directory) moved)
          "(src dst): mounted at dst")
      (ok (every (lambda (m) (getf m :read-only)) (plan-mounts p))
          "every spec mount is read-only"))))

(defunix plan-spec-mount-dotted
  (with-tree (root area ro outside)
    (let ((p (plan (sc:make-sandbox-spec :command '("true")
                                         :mounts (list (cons (namestring ro) "/srv/ro"))))))
      (ok (equal (list :guest "/srv/ro/" :host (ns ro) :read-only t :kind :directory)
                 (mount-at p "/srv/ro/"))
          "(src . dst), a directory: dst gets its trailing /"))))

(defunix plan-readable-under-writable-dropped
  (with-tree (root area ro outside)
    (let* ((sub (ensure-directories-exist (merge-pathnames "sub/" area)))
           (p (plan (area-spec area :readable (list sub)))))
      (ok (null (mount-at p (ns sub))) "the read-write area covers it")
      (ok (eq nil (getf (mount-at p (ns area)) :read-only))))))

(defunix plan-writable-under-readable-kept
  (with-tree (root area ro outside)
    (let* ((w (ensure-directories-exist (merge-pathnames "w/" ro)))
           (p (plan (sc:make-sandbox-spec
                     :confinement (sc:make-confinement :writable (list w) :readable (list ro)
                                                       :read :system :deny-read '()))))
           (guests (mapcar (lambda (m) (getf m :guest)) (plan-mounts p))))
      (ok (eq t (getf (mount-at p (ns ro)) :read-only)))
      (ok (eq nil (getf (mount-at p (ns w)) :read-only)) "the nested writable tree stays writable")
      (ok (< (position (ns ro) guests :test #'equal) (position (ns w) guests :test #'equal))
          "the parent is mounted first"))))

(defunix plan-physical-paths
  (with-tree (root area ro outside)
    (let ((link (merge-pathnames "area-link" root)))
      (pp:run (list "ln" "-s" (string-right-trim "/" (ns area)) (uiop:native-namestring link))
              :output :string :error-output :string)
      (let ((p (plan (area-spec (uiop:ensure-directory-pathname link)))))
        (ok (mount-at p (ns area)) "the symlink is resolved")
        (ok (null (mount-at p (concatenate 'string (uiop:native-namestring link) "/"))))
        (ok (equal (ns area) (plan-directory p)))))))

(defunix plan-duplicates-keep-first
  (with-tree (root area ro outside)
    (let ((p (plan (area-spec area :readable (list ro ro)))))
      (ok (= 1 (count (ns ro) (plan-mounts p) :key (lambda (m) (getf m :guest)) :test #'equal))))))

(defunix plan-network
  (with-tree (root area ro outside)
    (ok (eq :none (plan-network (plan (area-spec area)))))
    (ok (eq :direct (plan-network (plan (area-spec area :network :allow)))))
    (ok (eq :none (plan-network (plan '("true")))))
    (ok (eq :direct (plan-network (plan (sc:make-sandbox-spec :command '("true") :network :allow)))))))

(defunix plan-memory
  (with-tree (root area ro outside)
    (let ((mib (* 1024 1024)))
      (ok (= 1024 (plan-memory-mib (plan (area-spec area)))))
      (ok (= 512 (plan-memory-mib (plan (area-spec area) :backend (plan-backend :memory-mib 512)))))
      (ok (= 300 (plan-memory-mib (plan (area-spec area :memory-limit (* 300 mib))))))
      (ok (= 701 (plan-memory-mib (plan (area-spec area :memory-limit (1+ (* 700 mib))))))
          "bytes round up to whole MiB")
      (ok (= 400 (plan-memory-mib (plan (sc:make-sandbox-spec
                                         :memory-limit (* 400 mib)
                                         :confinement (area-confinement area :memory-limit (* 900 mib))))))
          "the smallest wins"))))

(defunix plan-env
  (with-tree (root area ro outside)
    (let ((tmp (tmp-dir root))
          (old (uiop:getenv "UNKERNEL_TEST_LEAK")))
      (setf (uiop:getenv "UNKERNEL_TEST_LEAK") "leak")
      (unwind-protect
           (let ((p (plan (sc:make-sandbox-spec
                           :confinement (area-confinement area :env '(("B" . "2") ("A" . "1") ("GONE")))
                           :env '(("C" . "4") ("B" . "3")))
                          :tmp tmp)))
             (ok (equal (list '("A" . "1") '("B" . "3") '("C" . "4") (cons "TMPDIR" (ns tmp)))
                        (plan-env p))
                 "confinement env, then the spec's (it wins), then TMPDIR; sorted; NIL values dropped")
             (ok (null (assoc "UNKERNEL_TEST_LEAK" (plan-env p) :test #'string=))
                 "host variables never enter the guest")
             (ok (null (assoc "PATH" (plan-env p) :test #'string=))
                 "not even PATH: the guest has its own"))
        (setf (uiop:getenv "UNKERNEL_TEST_LEAK") (or old ""))))))

(defunix plan-directory
  (with-tree (root area ro outside)
    (let* ((tmp (tmp-dir root))
           (other (ensure-directories-exist (merge-pathnames "other/" root))))
      (ok (equal (ns area)
                 (plan-directory (plan (sc:make-sandbox-spec
                                        :confinement (sc:make-confinement :writable (list area other)
                                                                          :read :system :deny-read '()))
                                       :tmp tmp)))
          "the first writable tree")
      (ok (equal (ns tmp) (plan-directory (plan '("true") :tmp tmp))) "no writable: the temp dir")
      (ok (equal +guest-home+
                 (plan-directory (plan (sc:make-sandbox-spec
                                        :confinement (sc:make-confinement :read :system :deny-read '()
                                                                          :tmp :none))
                                       :tmp tmp)))
          "neither: the guest user's home"))))

(defunix plan-tmp
  (with-tree (root area ro outside)
    (let ((tmp (tmp-dir root)))
      (let ((p (plan (area-spec area) :tmp tmp)))
        (ok (equal (ns tmp) (plan-tmp p)))
        (ok (mount-at p (ns tmp))))
      (let ((dry (plan (area-spec area))))
        (ok (null (plan-tmp dry)) "a dry plan: no temp dir yet")
        (ok (= 1 (length (plan-mounts dry))))
        (ok (null (assoc "TMPDIR" (plan-env dry) :test #'string=))))
      (let ((none (plan (area-spec area :tmp :none) :tmp tmp)))
        (ok (null (plan-tmp none)) ":tmp :none: no temp mount even when one is offered")
        (ok (null (mount-at none (ns tmp))))
        (ok (null (assoc "TMPDIR" (plan-env none) :test #'string=)))))))

(defunix plan-no-confinement
  (with-tree (root area ro outside)
    (let* ((tmp (tmp-dir root))
           (p (plan '("true") :tmp tmp)))
      (ok (equal (list (list :guest (ns tmp) :host (ns tmp) :read-only nil :kind :directory))
                 (plan-mounts p))
          "nothing of the host but the temp dir")
      (ok (eq :none (plan-network p))))))

(defunix plan-disk
  (with-tree (root area ro outside)
    (ok (equal (concatenate 'string +fake-home+ "guest/guest.img")
               (plan-disk (plan (area-spec area)))))))

(defun refusal (thunk type &key field policy missing)
  "→ NIL when THUNK signals TYPE with the given FIELD / POLICY / MISSING, else a message."
  (handler-case (progn (funcall thunk) (format nil "no ~s signalled" type))
    (condition (c)
      (cond ((not (typep c type)) (format nil "~s instead of ~s: ~a" (type-of c) type c))
            ((and field (not (eq field (sc:invalid-confinement-field c))))
             (format nil "field ~s, want ~s" (sc:invalid-confinement-field c) field))
            ((and policy (not (eq policy (sc:sandbox-denied-policy c))))
             (format nil "policy ~s, want ~s" (sc:sandbox-denied-policy c) policy))
            ((and missing (not (equal missing (sc:confinement-unsupported-missing c))))
             (format nil "missing ~s, want ~s" (sc:confinement-unsupported-missing c) missing))
            (t nil)))))

(defun confined (area &rest keys)
  (sc:make-sandbox-spec :command '("true")
                        :confinement (apply #'sc:make-confinement :writable (list area) keys)))

(deftest-parametrize plan-refusals
    ((name make type field policy missing)
     (:code (lambda (a) (declare (ignore a)) (sc:make-sandbox-spec :code "(+ 1 2)" :runtime :sbcl))
            'sc:sandbox-denied nil :lisp nil)
     (:cpu-limit (lambda (a) (declare (ignore a)) (sc:make-sandbox-spec :command '("true") :cpu-limit 1))
                 'sc:sandbox-denied nil :cpu-limit nil)
     (:network-beside-confinement
      (lambda (a) (sc:make-sandbox-spec :command '("true") :network :allow
                                        :confinement (area-confinement a)))
      'sc:invalid-confinement :network nil nil)
     (:egress-policy
      (lambda (a) (declare (ignore a))
        (sc:make-sandbox-spec :command '("true")
                              :network (sc:make-sandbox-network-policy
                                        :egress (list (sc:make-egress-rule :host "example.com" :port 443)))))
      'sc:sandbox-denied nil :egress nil)
     (:read-all-with-deny-read (lambda (a) (confined a :read :all :deny-read (list "/nonexistent-secret/")))
                               'sc:confinement-unsupported nil nil '(:deny-read))
     (:confinement-ports
      (lambda (a) (confined a :read :system :deny-read '()
                              :network (sc:make-sandbox-network-policy
                                        :egress (list (sc:make-egress-rule :host "*" :port 443)))))
      'sc:confinement-unsupported nil nil '(:network-ports))
     (:cpu-limit-confinement (lambda (a) (confined a :read :system :deny-read '() :cpu-limit 10))
                             'sc:confinement-unsupported nil nil '(:cpu-limit))
     (:file-size-limit (lambda (a) (confined a :read :system :deny-read '() :file-size-limit 10))
                       'sc:confinement-unsupported nil nil '(:file-size-limit))
     (:process-limit (lambda (a) (confined a :read :system :deny-read '() :process-limit 10))
                     'sc:confinement-unsupported nil nil '(:process-limit))
     (:read-all (lambda (a) (confined a :read :all :deny-read '()))
                'sc:invalid-confinement :read nil nil)
     (:env-inherit (lambda (a) (confined a :read :system :deny-read '() :env-mode :inherit))
                   'sc:invalid-confinement :env-mode nil nil)
     (:tmp-shared (lambda (a) (confined a :read :system :deny-read '() :tmp :shared))
                  'sc:invalid-confinement :tmp nil nil)
     (:writable-missing (lambda (a) (confined (merge-pathnames "missing/" a) :read :system :deny-read '()))
                        'sc:invalid-confinement :writable nil nil)
     (:readable-missing (lambda (a) (confined a :read :system :deny-read '()
                                                :readable (list (merge-pathnames "missing" a))))
                        'sc:invalid-confinement :readable nil nil)
     (:mount-relative-guest (lambda (a) (sc:make-sandbox-spec :command '("true")
                                                              :mounts (list (list (namestring a) "data/"))))
                            'sc:invalid-confinement :mounts nil nil)
     (:mount-missing-source (lambda (a) (sc:make-sandbox-spec :command '("true")
                                                              :mounts (list (namestring (merge-pathnames "missing/" a)))))
                            'sc:invalid-confinement :mounts nil nil)
     (:deny-read-inside-area (lambda (a) (confined a :read :system
                                                     :deny-read (list (ensure-directories-exist
                                                                       (merge-pathnames "secret/" a)))))
                             'sc:confinement-unsupported nil nil '(:deny-read))
     (:deny-read-is-the-area (lambda (a) (confined a :read :system :deny-read (list a)))
                             'sc:confinement-unsupported nil nil '(:deny-read))
     (:memory-too-small (lambda (a) (sc:make-sandbox-spec :memory-limit (* 100 1024 1024)
                                                          :confinement (area-confinement a)))
                        'sc:sandbox-denied nil :memory-limit nil)
     (:memory-too-large (lambda (a) (sc:make-sandbox-spec :memory-limit (* 4096 1024 1024)
                                                          :confinement (area-confinement a)))
                        'sc:sandbox-denied nil :memory-limit nil))
  (if (windows-p)
      (skip "planning tests use Unix paths: skipped on Windows")
      (with-tree (root area ro outside)
        (let ((message (refusal (lambda () (plan (funcall make area)))
                                type :field field :policy policy :missing missing)))
          (ok (null message) (format nil "~(~a~): ~a" name message))))))

(defunix plan-memory-from-backend-default
  ;; The backend's :memory-mib is bounded at construction (a type error, nothing probed).
  (ok (signals (make-unkernel-backend :memory-mib 100) 'type-error))
  (ok (signals (make-unkernel-backend :memory-mib 4096) 'type-error))
  (ok (signals (make-unkernel-backend :boot-timeout 0) 'type-error)))

(defun request-value (request key)
  (let ((entry (assoc key request :test #'equal)))
    (unless entry (error "no ~s in the request" key))
    (cdr entry)))

(defunix plan-request-shape
  (with-tree (root area ro outside)
    (let* ((tmp (tmp-dir root))
           (p (plan (area-spec area :readable (list (merge-pathnames "r" ro)) :env '(("K" . "v")))
                    :tmp tmp))
           (r (plan-request p)))
      (ok (equal '("unkernel" "distro" "disk" "mounts" "network" "memoryMiB" "cpus" "env" "directory" "tmp")
                 (mapcar #'car r))
          "exactly these keys, in this order")
      (ok (null (assoc "commands" r :test #'equal)) "host functions stay off")
      (ok (equal +unkernel-version+ (request-value r "unkernel")))
      (ok (equal `(("image" . ,+alpine-image+) ("sha256" . ,+alpine-sha256+)) (request-value r "distro")))
      (ok (equal `(("path" . ,(plan-disk p)) ("snapshot" . t)) (request-value r "disk"))
          "the guest disk is a snapshot: sessions never change it")
      (let ((mounts (request-value r "mounts")))
        (ok (vectorp mounts))
        (ok (= (length (plan-mounts p)) (length mounts)))
        (ok (equal `(("guest" . ,(ns area)) ("host" . ,(ns area)) ("readOnly") ("kind" . "directory"))
                   (find (ns area) mounts :key (lambda (m) (cdr (assoc "guest" m :test #'equal)))
                                          :test #'equal)))
        (ok (equal `(("guest" . ,(ns (merge-pathnames "r" ro))) ("host" . ,(ns (merge-pathnames "r" ro)))
                     ("readOnly" . t) ("kind" . "file"))
                   (find (ns (merge-pathnames "r" ro)) mounts
                         :key (lambda (m) (cdr (assoc "guest" m :test #'equal))) :test #'equal))))
      (ok (equal "none" (request-value r "network")))
      (ok (eql 1024 (request-value r "memoryMiB")))
      (ok (eql 1 (request-value r "cpus")))
      (let ((env (request-value r "env")))
        (ok (hash-table-p env))
        (ok (equal "v" (gethash "K" env)))
        (ok (equal (ns tmp) (gethash "TMPDIR" env))))
      (ok (equal (ns area) (request-value r "directory")))
      (ok (equal (ns tmp) (request-value r "tmp"))))))

(defunix plan-request-encodes
  (with-tree (root area ro outside)
    (let* ((dry (plan (area-spec area :readable (list ro) :tmp :none :network :allow)))
           (decoded (json:decode (json:encode (plan-request dry)))))
      (ok (equal "direct" (gethash "network" decoded)))
      (ok (eq :null (gethash "tmp" decoded)) "no temp dir → null")
      (ok (hash-table-p (gethash "env" decoded)) "an empty env is still an object")
      (ok (zerop (hash-table-count (gethash "env" decoded))))
      (ok (null (nth-value 1 (gethash "commands" decoded))))
      (let ((by-guest (map 'list (lambda (m) (cons (gethash "guest" m) (gethash "readOnly" m)))
                           (gethash "mounts" decoded))))
        (ok (equal (list (cons (ns area) nil) (cons (ns ro) t))
                   (sort by-guest #'string< :key #'car))
            "readOnly is false only for the writable tree")))))
