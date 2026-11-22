(in-package #:compute-backend-unkernel)

;;; The session plan: a sandbox spec (and its confinement) turned into what the
;;; kernel is booted with. Pure: no process, nothing created, no availability
;;; probe (paths are resolved with SC:PHYSICAL-PATH and checked to exist).
;;;
;;; Given (contract): the class and readers. Stubbed: PLAN-SESSION, PLAN-REQUEST.

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
  (declare (ignore backend spec tmp))
  (%unkernel0-pending "plan-session"))

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
  (declare (ignore plan))
  (%unkernel0-pending "plan-request"))
