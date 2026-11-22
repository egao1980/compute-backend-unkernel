(in-package #:compute-backend-unkernel)

;;; The session plan: a sandbox spec (and its confinement) turned into what the
;;; kernel is booted with. Pure: no process, nothing created, no availability
;;; probe (paths are resolved with SC:PHYSICAL-PATH and checked to exist).
;;;
;;; Given (contract): the class and readers. Implemented (R4h-4a): PLAN-SESSION, PLAN-REQUEST.

(defclass unkernel-plan ()
  ((mounts :initarg :mounts :reader plan-mounts
           :documentation "List of plists (:guest g :host h :read-only bool :kind :directory|:file),
sorted by :GUEST (STRING<), so a parent is mounted before what is nested in it.")
   (network :initarg :network :reader plan-network :documentation ":NONE or :DIRECT.")
   (memory-mib :initarg :memory-mib :reader plan-memory-mib)
   (env :initarg :env :reader plan-env
        :documentation "Alist (name . value) sorted by name (STRING<): what the guest adds to its
own login environment. Only the confinement's :ENV, the spec's :ENV and TMPDIR.")
   (directory :initarg :directory :reader plan-directory
              :documentation "The start directory (a guest namestring ending in /).")
   (tmp :initarg :tmp :reader plan-tmp
        :documentation "The private temp dir (a namestring ending in /), or NIL.")
   (disk :initarg :disk :reader plan-disk
         :documentation "Native namestring of HOME/guest/guest.img."))
  (:documentation "What one session boots with. Made by PLAN-SESSION."))

(defun unkernel-plan-p (object)
  (typep object 'unkernel-plan))

(defun plan-session (backend spec &key tmp)
  "SPEC (a SANDBOX-SPEC or anything COERCE-SANDBOX-SPEC takes) on BACKEND → an UNKERNEL-PLAN.
TMP: the session's private temp dir (a directory pathname or namestring), or NIL for a
dry plan (no temp mount, PLAN-TMP NIL, no TMPDIR).

CONFINEMENT = the spec's :CONFINEMENT, else (make-confinement :read :system :deny-read '()).
Mounts, every path physical (SC:PHYSICAL-PATH), each at the same path in the guest:
  :WRITABLE entries                       read-write, :kind :directory
  TMP, when CONFINEMENT's :TMP is :PRIVATE read-write, :kind :directory
  :READABLE entries                       read-only, :kind :directory or :file
  the spec's :MOUNTS (path | (src dst) | (src . dst); DST an absolute POSIX guest path,
  ending in / when SRC is a directory)    read-only
  A read-only entry at or under a read-write one is dropped (the read-write tree covers
  it); a duplicate guest path keeps its first entry.
Network: CONFINEMENT's :NETWORK when the spec has a confinement, else the spec's :NETWORK:
  :NONE → :NONE, :ALLOW → :DIRECT.
Memory MiB: the smallest of the spec's :MEMORY-LIMIT and CONFINEMENT's :MEMORY-LIMIT
  (bytes, rounded up to whole MiB) and UNKERNEL-BACKEND-MEMORY-MIB.
Env: CONFINEMENT's :ENV (entries whose value is NIL dropped), then the spec's :ENV (it
  wins on a name), then (\"TMPDIR\" . TMP) when TMP is mounted; sorted by name.
Directory: the first :WRITABLE entry, else TMP when mounted, else +GUEST-HOME+.
Disk: HOME/guest/guest.img (not checked here).

Refusals, in this order, before anything else:
  spec :CODE                                    → SANDBOX-DENIED :policy :lisp
  spec :CPU-LIMIT                               → SANDBOX-DENIED :policy :cpu-limit
  spec :CONFINEMENT and a spec :NETWORK other than :NONE
                                                → INVALID-CONFINEMENT :field :network
  no confinement and a spec network policy      → SANDBOX-DENIED :policy :egress
  CONFINEMENT-REQUIREMENTS outside +UNKERNEL-FEATURES+
                                                → CONFINEMENT-UNSUPPORTED :missing (in order)
  :READ :ALL                                    → INVALID-CONFINEMENT :field :read
  :ENV-MODE :INHERIT                            → INVALID-CONFINEMENT :field :env-mode
  :TMP :SHARED                                  → INVALID-CONFINEMENT :field :tmp
  a :WRITABLE entry that is not an existing directory, a :READABLE entry that does not exist
                                                → INVALID-CONFINEMENT :field :writable / :readable
  a spec mount whose source does not exist or whose guest path is not absolute
                                                → INVALID-CONFINEMENT :field :mounts
  a :DENY-READ entry at or under a mounted path → CONFINEMENT-UNSUPPORTED :missing (:deny-read)
  memory outside [+MIN-MEMORY-MIB+, +MAX-MEMORY-MIB+]
                                                → SANDBOX-DENIED :policy :memory-limit"
  (let* ((spec (sc:coerce-sandbox-spec spec))
         (confinement (%plan-confinement spec)))
    (%check-refusals backend spec confinement)
    (let* ((resolved (sc:resolve-confinement confinement)) ; :WRITABLE refusals
           (tmp (and tmp (eq (sc:confinement-tmp resolved) :private) (%tmp-namestring tmp)))
           (mounts (progn (%check-readable resolved)
                          (%plan-mounts spec resolved tmp)))) ; :MOUNTS refusals
      (%check-deny-read backend resolved mounts)
      (make-instance 'unkernel-plan
                     :mounts mounts
                     :network (%plan-network spec)
                     :memory-mib (%plan-memory-mib backend spec confinement)
                     :env (%plan-env spec confinement tmp)
                     :directory (cond ((sc:confinement-writable resolved)
                                       (%ns (first (sc:confinement-writable resolved))))
                                      (tmp tmp)
                                      (t +guest-home+))
                     :tmp tmp
                     :disk (concatenate 'string
                                        (%ns (unkernel-backend-home backend))
                                        "guest/guest.img")))))

;;; Plan helpers (pure).

(defun %ns (pathname)
  (uiop:native-namestring pathname))

(defun %plan-confinement (spec)
  "SPEC's confinement, else the strict default (:read :system, nothing denied)."
  (or (sc:sandbox-spec-confinement spec)
      (sc:make-confinement :read :system :deny-read '())))

(defun %plan-tmp-mode (spec)
  ":PRIVATE, :SHARED or :NONE: the :TMP of SPEC's (or the default) confinement."
  (sc:confinement-tmp (%plan-confinement spec)))

(defun %check-refusals (backend spec confinement)
  "The refusals that need no path resolution, in PLAN-SESSION's documented order."
  (let ((given (sc:sandbox-spec-confinement spec))
        (network (sc:sandbox-spec-network spec)))
    (when (sc:sandbox-spec-code spec)
      (error 'sc:sandbox-denied :spec spec :policy :lisp
                                :message "compute-backend-unkernel 0.1.0 runs :command only (:code needs the R4h-4b SBCL session core)"))
    (when (sc:sandbox-spec-cpu-limit spec)
      (error 'sc:sandbox-denied :spec spec :policy :cpu-limit
                                :message "the unkernel guest has no CPU limit"))
    (when (and given (not (eq network :none)))
      (error 'sc:invalid-confinement :spec spec :field :network :value network
                                     :message "with a :confinement, its :network decides; the spec's must be :none"))
    (when (and (not given) (sc:sandbox-network-policy-p network))
      (error 'sc:sandbox-denied :spec spec :policy :egress
                                :message "egress policies are not enforced by the unkernel backend (only :none or :allow)"))
    (let ((missing (remove-if (lambda (feature) (member feature +unkernel-features+))
                              (sc:confinement-requirements confinement))))
      (when missing
        (error 'sc:confinement-unsupported :spec spec :backend backend :missing missing)))
    (when (eq (sc:confinement-read confinement) :all)
      (error 'sc:invalid-confinement :spec spec :field :read :value :all
                                     :message "the guest sees only its mounts: use :read :system"))
    (when (eq (sc:confinement-env-mode confinement) :inherit)
      (error 'sc:invalid-confinement :spec spec :field :env-mode :value :inherit
                                     :message "host variables never enter the guest"))
    (when (eq (sc:confinement-tmp confinement) :shared)
      (error 'sc:invalid-confinement :spec spec :field :tmp :value :shared
                                     :message "a shared temp dir would mount the host's whole temp directory"))))

(defun %tmp-namestring (tmp)
  "TMP (a directory pathname or namestring) as a physical directory namestring."
  (let ((p (if (stringp tmp) (uiop:parse-native-namestring tmp) tmp)))
    (%ns (uiop:ensure-directory-pathname (sc:physical-path (uiop:ensure-directory-pathname p))))))

(defun %directory-ns-p (ns)
  (and (plusp (length ns)) (char= #\/ (char ns (1- (length ns))))))

(defun %under-p (target entry)
  "TARGET (a namestring) is ENTRY or below it: ENTRY a directory namestring (ending in /)
covers itself, with or without its slash, and everything below; a file entry only itself."
  (if (%directory-ns-p entry)
      (or (uiop:string-prefix-p entry target)
          (string= target entry :end2 (1- (length entry))))
      (string= target entry)))

(defun %mount (guest host read-only kind)
  (list :guest guest :host host :read-only read-only :kind kind))

(defun %mount-kind (physical)
  (if (uiop:directory-exists-p physical) :directory :file))

(defun %spec-mount (spec m)
  "One spec :MOUNTS designator (path | (src dst) | (src . dst)) → a read-only plan mount."
  (flet ((refuse (message)
           (error 'sc:invalid-confinement :spec spec :field :mounts :value m :message message))
         (path-of (x)
           (cond ((pathnamep x) x)
                 ((and (stringp x) (plusp (length x))) (uiop:parse-native-namestring x))
                 (t nil))))
    (multiple-value-bind (src dst)
        (cond ((atom m) (values m nil))
              ((consp (cdr m)) (values (first m) (second m)))
              (t (values (car m) (cdr m))))
      (let ((src-path (path-of src)))
        (unless (and src-path (uiop:absolute-pathname-p src-path))
          (refuse "the source is not an absolute path"))
        (let* ((physical (sc:physical-path src-path))
               (kind (cond ((uiop:directory-exists-p physical) :directory)
                           ((uiop:file-exists-p physical) :file)
                           (t (refuse "the source does not exist"))))
               (physical (if (eq kind :directory) (uiop:ensure-directory-pathname physical) physical))
               (host (%ns physical))
               (guest (cond ((null dst) host)
                            ((pathnamep dst) (%ns dst))
                            ((stringp dst) dst)
                            (t (refuse "the guest path is not a string")))))
          (unless (and (plusp (length guest)) (char= #\/ (char guest 0)))
            (refuse "the guest path is not an absolute POSIX path"))
          (when (search "/../" (concatenate 'string guest "/"))
            (refuse "the guest path contains .."))
          (when (and (eq kind :directory) (not (%directory-ns-p guest)))
            (setf guest (concatenate 'string guest "/")))
          (%mount guest host t kind))))))

(defun %plan-mounts (spec resolved tmp)
  "Every mount of the plan: writable and TMP read-write, readable and the spec's mounts
read-only; read-only entries under a read-write tree dropped, duplicates keep the first,
sorted by guest path."
  (let* ((entries
           (append (mapcar (lambda (w) (let ((ns (%ns w))) (%mount ns ns nil :directory)))
                           (sc:confinement-writable resolved))
                   (when tmp (list (%mount tmp tmp nil :directory)))
                   (mapcar (lambda (r)
                             (let* ((kind (%mount-kind r))
                                    (ns (%ns (if (eq kind :directory) (uiop:ensure-directory-pathname r) r))))
                               (%mount ns ns t kind)))
                           (sc:confinement-readable resolved))
                   (mapcar (lambda (m) (%spec-mount spec m)) (sc:sandbox-spec-mounts spec))))
         (rw (loop for m in entries unless (getf m :read-only) collect (getf m :guest)))
         (kept (remove-if (lambda (m)
                            (and (getf m :read-only)
                                 (some (lambda (g) (%under-p (getf m :guest) g)) rw)))
                          entries)))
    (stable-sort (remove-duplicates kept :key (lambda (m) (getf m :guest))
                                         :test #'string= :from-end t)
                 #'string< :key (lambda (m) (getf m :guest)))))

(defun %check-readable (resolved)
  (dolist (r (sc:confinement-readable resolved))
    (unless (or (uiop:directory-exists-p r) (uiop:file-exists-p r))
      (error 'sc:invalid-confinement :field :readable :value r
                                     :message "a readable entry that does not exist"))))

(defun %check-deny-read (backend resolved mounts)
  "Fail closed: a :DENY-READ entry at or under a mounted host path (or a mount inside a
denied tree) cannot be hidden from the guest."
  (dolist (d (sc:confinement-deny-read resolved))
    (let ((ns (%ns d)))
      (when (some (lambda (m)
                    (let ((host (getf m :host)))
                      (or (%under-p ns host)
                          (and (%directory-ns-p ns) (%under-p host ns)))))
                  mounts)
        (error 'sc:confinement-unsupported :backend backend :missing '(:deny-read))))))

(defun %plan-network (spec)
  (let* ((given (sc:sandbox-spec-confinement spec))
         (network (if given (sc:confinement-network given) (sc:sandbox-spec-network spec))))
    (ecase network
      (:none :none)
      (:allow :direct))))

(defun %bytes->mib (bytes)
  (and bytes (ceiling bytes 1048576)))

(defun %plan-memory-mib (backend spec confinement)
  (let* ((asked (remove nil (list (%bytes->mib (sc:sandbox-spec-memory-limit spec))
                                  (%bytes->mib (sc:confinement-memory-limit confinement)))))
         (mib (reduce #'min asked :initial-value (unkernel-backend-memory-mib backend))))
    ;; Every limit asked for must be one the guest can have, not only the smallest.
    (unless (and (<= +min-memory-mib+ mib +max-memory-mib+)
                 (every (lambda (m) (<= m +max-memory-mib+)) asked))
      (error 'sc:sandbox-denied :spec spec :policy :memory-limit
                                :message (format nil "~d MiB is outside the guest's ~d–~d MiB"
                                                 mib +min-memory-mib+ +max-memory-mib+)))
    mib))

(defun %env-name (name)
  (if (stringp name) name (string name)))

(defun %env-value (value)
  (and value (if (stringp value) value (princ-to-string value))))

(defun %env-put (env name value)
  (let ((rest (remove name env :key #'car :test #'string=)))
    (if value (acons name value rest) rest)))

(defun %plan-env (spec confinement tmp)
  (let ((env '()))
    (dolist (e (sc:confinement-env confinement))
      (setf env (%env-put env (%env-name (car e)) (%env-value (cdr e)))))
    (dolist (e (sc:sandbox-spec-env spec))
      (setf env (%env-put env (%env-name (car e)) (%env-value (cdr e)))))
    (when tmp
      (setf env (%env-put env "TMPDIR" tmp)))
    (stable-sort env #'string< :key #'car)))

(defun plan-request (plan)
  "PLAN as the session.open params: a JSON-ready value (json-protocol: an alist is an
object in its order, a vector an array, a hash-table an object with sorted keys, NIL
false, :NULL null), with exactly these keys in this order:
  \"unkernel\"  +UNKERNEL-VERSION+
  \"distro\"    ((\"image\" . +ALPINE-IMAGE+) (\"sha256\" . +ALPINE-SHA256+))
  \"disk\"      ((\"path\" . (plan-disk plan)) (\"snapshot\" . T))
  \"mounts\"    a vector, one alist per plan mount:
              ((\"guest\" . g) (\"host\" . h) (\"readOnly\" . T|NIL) (\"kind\" . \"directory\"|\"file\"))
  \"network\"   \"none\" | \"direct\"
  \"memoryMiB\" (plan-memory-mib plan)
  \"cpus\"      1
  \"env\"       an EQUAL hash-table of (plan-env plan) (an empty one encodes as {})
  \"directory\" (plan-directory plan)
  \"tmp\"       (plan-tmp plan), or :NULL
There is no \"commands\" key, ever: host functions stay off."
  (let ((env (make-hash-table :test 'equal)))
    (loop for (name . value) in (plan-env plan)
          do (setf (gethash name env) value))
    (list (cons "unkernel" +unkernel-version+)
          (cons "distro" (list (cons "image" +alpine-image+)
                               (cons "sha256" +alpine-sha256+)))
          (cons "disk" (list (cons "path" (plan-disk plan))
                             (cons "snapshot" t)))
          (cons "mounts" (map 'vector
                              (lambda (m)
                                (list (cons "guest" (getf m :guest))
                                      (cons "host" (getf m :host))
                                      (cons "readOnly" (and (getf m :read-only) t))
                                      (cons "kind" (ecase (getf m :kind)
                                                     (:directory "directory")
                                                     (:file "file")))))
                              (plan-mounts plan)))
          (cons "network" (ecase (plan-network plan)
                            (:none "none")
                            (:direct "direct")))
          (cons "memoryMiB" (plan-memory-mib plan))
          (cons "cpus" 1)
          (cons "env" env)
          (cons "directory" (plan-directory plan))
          (cons "tmp" (or (plan-tmp plan) :null)))))
