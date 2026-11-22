(defpackage #:compute-backend-unkernel/tests
  (:use #:cl #:rove #:compute-backend-unkernel)
  (:local-nicknames (#:sc #:compute-protocol)
                    (#:pp #:process-protocol)
                    (#:json #:json-protocol)))

(in-package #:compute-backend-unkernel/tests)
