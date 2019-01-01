(library (tojoqk aws request)
  (export aws/get aws/post
          current-access-key-id
          current-secret-access-key
          current-region)
  (import (chezscheme)
          (hashing sha-2)
          (tojoqk http)
          (tojoqk percent-encoding)
          (only (srfi :13)
                string-tokenize string-join
                string-trim-both string-index)
          (only (srfi :14) char-set char-set-complement))

  (define current-access-key-id
    (make-parameter (getenv "AWS_ACCESS_KEY_ID")))

  (define current-secret-access-key
    (make-parameter (getenv "AWS_SECRET_ACCESS_KEY")))

  (define current-region
    (make-parameter
     (cond
      [(getenv "AWS_DEFAULT_REGION") => values]
      [else "us-east-1"])))

  (define (single? x)
    (and (pair? x)
         (null? (cdr x))))

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

  ;; Task1
  (define (make-canonical-request method
                                  canonical-path
                                  canonical-query-string
                                  canonical-headers
                                  signed-headers
                                  payload)
    (format "~@{~a~^~%~}"
            method
            canonical-path
            (or canonical-query-string "")
            canonical-headers
            signed-headers
            (hash (or payload ""))))

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
  (define (make-signature key date region service string-to-sign)
    (chained-sign (string-append "AWS4" key)
                  (datestamp date)
                  region
                  service
                  "aws4_request"
                  string-to-sign))

  ;; Task4
  (define (make-authorization-header access-key-id  scope signed-headers signature)
    (format "AWS4-HMAC-SHA256 Credential=~a/~a, SignedHeaders=~a, Signature=~a"
            access-key-id
            scope
            signed-headers
            signature))

  (define (aws/get service path headers queries)
    (aws "GET" service path headers queries #f))

  (define (aws/post service path headers queries payload)
    (aws "POST" service path headers queries payload))

  (define (aws method service path headers queries payload)
    (unless (current-access-key-id)
      (error 'aws "no access-key-id"))
    (unless (current-secret-access-key)
      (error 'aws "no secret-access-key"))
    (let* ([canonical-query-string
            (cond
             [(null? queries) #f]
             [queries => query-canonicalize]
             [else #f])]
           [region (current-region)]
           [date (current-date 0)]
           [host (format "~a~:[~;~:*.~a~].amazonaws.com"
                         service region)]
           [headers (cons* `("Host" . ,host)
                           `("x-amz-date" . ,(amzdate date))
                           headers)]
           [signed-headers (make-signed-headers headers)]
           [canonical-path
            (cond
             [(string=? "s3" service)
              (uri-canonicalize path)]
             [else
              (uri-canonicalize (uri-canonicalize path))])]
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
                                    payload)]
           [scope (make-credential-scope date region service)]
           [string-to-sign (make-string-to-sign date
                                                scope
                                                (hash
                                                 canonical-request))]
           [signature (make-signature (current-secret-access-key)
                                      date
                                      region
                                      service
                                      string-to-sign)]
           [authorization-header
            (make-authorization-header (current-access-key-id)
                                       scope
                                       signed-headers
                                       signature)]
           [headers
            (cons `("Authorization" . ,authorization-header)
                  headers)]
           [endpoint (format "https://~a~:[~;~:*~a~]"
                             canonical-uri
                             canonical-query-string)])
      (cond
       [(string=? method "GET")
        (http/get endpoint headers)]
       [(string=? method "POST")
        (http/post endpoint payload headers)])))

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

  (define string-split
    (case-lambda
      [(str sep)
       (string-split str sep 0)]
      [(str sep start)
       (string-split str sep start #f)]
      [(str sep start count)
       (define (make-last i)
         (list (substring str i (string-length str))))
       (let rec ([i 0]
                 [c 0])
         (cond
          [(and count (= count c)) (make-last i)]
          [(string-index str sep i)
           => (lambda (idx)
                (cons (substring str i idx)
                      (rec (+ idx 1) (+ c 1))))]
          [else (make-last i)]))]))
  )
