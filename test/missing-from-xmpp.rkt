#lang racket/base

(provide (all-defined-out))

(require "../main.rkt")
(require openssl)
(require racket/dict)
(require (planet lizorkin/sxml:2:1/sxml)) ;; encoding xml
(require (planet lizorkin/ssax:2:0/ssax)) ;; decoding xml
;;(require scheme/tcp )
(define ssl-port 5223)

(define (read-async in)
  (bytes->string/utf-8 (list->bytes (read-async-bytes in))))
(define (read-async-bytes in)
  (let ((bstr '()))
    (when (sync/timeout 0 in)
      (set! bstr (cons (read-byte in) (read-async-bytes in)))) bstr))

(define debug? #t)

(define debugf
  (case-lambda
    ((str) (when debug? (printf str)))
    ((str . dir) (when debug? (apply printf (cons str dir))))))

(define (clean str)
  (let ((test (substring str 0 3)))
    (cond ((string-ci=? test "<me") str)
          ((string-ci=? test "<iq") str)
          ((string-ci=? test "<pr") str)
          ((string-ci=? test "<ur") str)
          (else
           (debugf "~%recieved: ~a ~%parsed as <null/>~%~%" str)
           "<null/>"))))

(define (parse-xmpp-response str)
  (when (> (string-length str) 0)
    (let ((sz (ssax:xml->sxml (open-input-string (clean str)) '())))
      ;;(let ((sz (lazy:xml->sxml (open-input-string str) '())))
      (cond
       ((equal? '(null) (cadr sz))
        (newline))
       ((equal? 'message (caadr sz))
        (run-xmpp-handler 'message sz))
       ((equal? 'iq (caadr sz))
        (run-xmpp-handler 'iq sz))
       ((equal? 'presence (caadr sz))
        (run-xmpp-handler 'presence sz))
       (else (run-xmpp-handler 'other sz))))))

(define xmpp-handlers (make-hash)) ;; a hash of tags and functions (possibly extend to using sxpaths and multiple handlers)

(define (set-xmpp-handler type fcn)
  (dict-set! xmpp-handlers type fcn))

(define (remove-xmpp-handler type fcn)
  (dict-remove! xmpp-handlers type fcn))

(define (run-xmpp-handler type sz)
  (let ((fcn (dict-ref xmpp-handlers type #f)))
    (when fcn (begin
                (debugf "attempting to run handler ~a.~%" fcn)
                (fcn sz)))))

(define (xmpp-response-handler in)
  (thread (lambda ()
            (let loop ()
              (parse-xmpp-response (read-async in))
              (sleep 0.1) ;; slight delay to avoid a tight loop
              (loop)))))

(define xmpp-in-port (make-parameter #f))
(define xmpp-out-port (make-parameter #F))

(define (send str)
  (debugf "sending: ~a ~%~%" str)
  (let* ((p-out (xmpp-out-port))
         (out (if p-out p-out xmpp-out-port-v)))
    (fprintf out "~A~%" str) (flush-output out)))

(define-syntax with-xmpp-session
  (syntax-rules ()
    ((_ jid pass form . forms)
     (let ((host (jid-host jid))
           (user (jid-user jid))
           (resource (jid-resource jid)))
       (let-values (((in out)
                     (ssl-connect host ssl-port 'tls)))
         ;;(tcp-connect host port)))
         (parameterize ((xmpp-in-port in)
                        (xmpp-out-port out))
           (file-stream-buffer-mode out 'line)
           (xmpp-response-handler in)
           (send (xmpp-stream host))
           (send (xmpp-session host))
                                        ;(starttls in out)
           (send (xmpp-auth user pass resource))
           (send (presence))
           (begin form . forms)
           (close-output-port out)
           (close-input-port in)))))))

;; NOTE: this will only work with a single connection to a host, however multiple sessions to that host may be possible
(define xmpp-in-port-v (current-input-port))
(define xmpp-out-port-v (current-output-port))

(define (start-xmpp-session jid pass)
  (let ((host (jid-host jid))
        (user (jid-user jid))
        (resource (jid-resource jid)))
    (let-values (((in out)
                  (ssl-connect host ssl-port 'tls)))
      ;;(tcp-connect host port)))
      (set! xmpp-in-port-v in)
      (set! xmpp-out-port-v out)
      (file-stream-buffer-mode out 'line)
      (xmpp-response-handler in)
      (send (xmpp-stream host))
      (send (xmpp-session host))
      ;;(starttls in out)
      (send (xmpp-auth user pass resource))
      (send (presence)))))

(define (close-xmpp-session)
  (close-output-port xmpp-out-port-v)
  (close-input-port xmpp-in-port-v))