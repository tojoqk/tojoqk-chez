(library (tojoqk unstable aws request)
  (export aws/get aws/post aws/put aws/delete)
  (import (chezscheme)
          (hashing sha-2)
          (tojoqk http)
          (tojoqk unstable aws common)
          (only (tojoqk util sexpr) single?)
          (only (tojoqk util string) string-split)
          (tojoqk percent-encoding)
          (only (srfi :13)
                string-tokenize string-join
                string-trim-both)
          (only (srfi :14) char-set char-set-complement))

  ;; Task1
  (define (make-canonical-request method
                                  canonical-path
                                  canonical-query-string
                                  canonical-headers
                                  signed-headers
                                  x-amz-content-sha256)
    (format "~@{~a~^~%~}"
            method
            canonical-path
            (or canonical-query-string "")
            canonical-headers
            signed-headers
            x-amz-content-sha256))

  (define (make-credential-scope date region service)
    (format "~@{~a~^/~}"
            (datestamp date)
            region
            service
            "aws4_request"))

  ;; Task2
  (define (make-string-to-sign date credential-scope signed-request)
    (format "~@{~a~^~%~}"
            "AWS4-HMAC-SHA256"
            (amzdate date)
            credential-scope
            signed-request))

  ;; Task 3
  (define (get-signature key date region service string-to-sign)
    (chained-sign (string-append "AWS4" key)
                  (datestamp date)
                  region
                  service
                  "aws4_request"
                  string-to-sign))

  ;; Task4
  (define (make-authorization-header access-key-id scope signed-headers signature)
    (format "AWS4-HMAC-SHA256 Credential=~a/~a, SignedHeaders=~a, Signature=~a"
            access-key-id
            scope
            signed-headers
            signature))

  (define (adjoin-header header headers)
    (cond
     [(assp (lambda (c) (string-ci=? (car header) c)) headers)
      headers]
     [else
      (cons header headers)]))

  (define (aws/get host service canonical-path queries headers)
    (aws "GET" host service canonical-path queries headers ""))

  (define (aws/post host service canonical-path queries headers payload)
    (aws "POST" host service canonical-path queries headers payload))

  (define (aws/put host service canonical-path queries headers payload)
    (aws "PUT" host service canonical-path queries headers payload))

  (define (aws/delete host service canonical-path queries headers)
    (aws "DELETE" host service canonical-path queries headers ""))

  (define (aws method host service canonical-path queries headers payload)
    (unless (current-access-key-id)
      (error 'authorize-headers "no access-key-id"))
    (unless (current-secret-access-key)
      (error 'authorize-headers "no secret-access-key"))
    (let* ([canonical-query-string
            (cond
             [(null? queries) #f]
             [queries => query-canonicalize]
             [else #f])]
           [date (current-date 0)]
           [region (current-region)]
           [x-amz-content-sha256 (hash (or payload ""))]
           [headers (append
                     `(("x-amz-date" . ,(amzdate date))
                       ("x-amz-content-sha256" . ,x-amz-content-sha256)
                       ("Host" . ,host))
                     headers)]
           [signed-headers (make-signed-headers headers)]
           [canonical-uri
            (format "~a~a~:[~;?~]"
                    host canonical-path
                    canonical-query-string)]
           [canonical-headers (header-canonicalize headers)]
           [canonical-request
            (make-canonical-request method
                                    canonical-path
                                    canonical-query-string
                                    canonical-headers
                                    signed-headers
                                    x-amz-content-sha256)]
           [scope (make-credential-scope date region service)]
           [string-to-sign (make-string-to-sign
                            date
                            scope
                            (hash canonical-request))]
           [signature (get-signature (current-secret-access-key)
                                     date
                                     region
                                     service
                                     string-to-sign)]
           [headers (cons
                     (cons "Authorization"
                           (make-authorization-header
                            (current-access-key-id)
                            scope
                            signed-headers
                            signature))
                     headers)]
           [endpoint
            (format "https://~a~:[~;~:*~a~]"
                    canonical-uri canonical-query-string)])
      (cond
       [(string=? method "GET")
        (http/get endpoint headers)]
       [(string=? method "POST")
        (http/post endpoint payload headers)]
       [(string=? method "PUT")
        (http/put endpoint payload headers)]
       [(string=? method "DELETE")
        (http/delete endpoint headers)])))

  (define (chained-sign key msg . msgs)
    (let rec ([key (string->utf8 key)]
              [msg msg]
              [msgs msgs])
      (cond
       [(null? msgs)
        (sha-256->string
         (hmac-sha-256 key (string->utf8 msg)))]
       [else
        (rec (sha-256->bytevector
              (hmac-sha-256 key
                            (string->utf8 msg)))
             (car msgs)
             (cdr msgs))])))

  (define (amzdate date)
    (format "~4,'0d~2,'0d~2,'0dT~2,'0d~2,'0d~2,'0dZ"
            (date-year date)
            (date-month date)
            (date-day date)
            (date-hour date)
            (date-minute date)
            (date-second date)))

  (define (datestamp date)
    (format "~4,'0d~2,'0d~2,'0d"
            (date-year date)
            (date-month date)
            (date-day date)))

  (define (uri-canonicalize path)
    (string-join
     (map percent-encode (string-split path #\/))
     "/"))

  (define (query-canonicalize params)
    (string-join
     (map (lambda (param)
            (string-append
             (percent-encode (car param))
             "="
             (percent-encode (cdr param))))
          (sort (lambda (x y) (string<=? (car x) (car y)))
                params))
     "&"))

  (define (header-canonicalize headers)
    (format "~:{~a:~a~%~}"
            (sort (lambda (x y) (string<=? (car x) (car y)))
                  (map (lambda (x)
                         (list
                          (string-downcase (car x))
                          (string-trim-both
                           (string-join
                            (string-tokenize (cdr x)
                                             (char-set-complement
                                              (char-set #\space)))
                            " ")
                           #\space)))
                       headers))))

  (define (make-signed-headers headers)
    (format "~{~a~^;~}"
            (sort string<=?
                  (map (lambda (x) (string-downcase (car x))) headers))))

  (define (hash x)
    (sha-256->string
     (sha-256 (cond
               [(string? x) (string->utf8 x)]
               [(bytevector? x) x]
               [else
                (assertion-violation 'hash "error" x)]))))
  )
