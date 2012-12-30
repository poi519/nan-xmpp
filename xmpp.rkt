;;; A basic XMPP library which should conform to RFCs 3920 and 3921
;;;
;;; Copyright (C) 2009 FoAM vzw. 
;;;
;;;  This package is free software: you can redistribute it and/or
;;;  modify it under the terms of the GNU Lesser General Public
;;;  License as published by the Free Software Foundation, either
;;;  version 3 of the License, or (at your option) any later version.
;;;
;;;  This program is distributed in the hope that it will be useful,
;;;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;;;  Lesser General Public License for more details.
;;;
;;;  You can find a copy of the GNU Lesser General Public License at
;;;  http://www.gnu.org/licenses/lgpl-3.0.html.
;;;
;;; Authors 
;;;
;;;  nik gaffney <nik@fo.am>
;;;  maria stein <marune@pyos.net>
;;;
;;; Requirements
;;;
;;;  PLT for now. TLS requires a version of PLT > 4.1.5.3
;;;
;;; Commentary
;;;
;;;  Still a long way from implementing even a minimal subset of XMPP
;;; 
;;;  features implemented
;;;   - plaintext sessions on port 5222 
;;;   - "old sytle" ssl sessions on port 5223 (default)
;;;   - authenticate using an existing account
;;;   - send messages (rfc 3921 sec.4)
;;;   - send presence (rfc 3921 sec.5)
;;;   - parse (some) xml reponses from server
;;;   - handlers for responses
;;;   - basic roster handling (rfc 3921 sec.7)
;;;
;;;  features to implement
;;;   - account creation
;;;   - managing subscriptions & rosters (rfc 3921 sec.6 & 8)
;;;   - error handling for rosters (rfc 3921 sec.7)
;;;   - plaintext/tls/sasl negotiation (rfc 3920 sec.5 & 6) 
;;;   - encrypted connections using tls on port 5222
;;;   - correct namespaces in sxml
;;;   - message types
;;;   - maintain session ids
;;;   - maintain threads
;;;   - error handling
;;;   - events
;;;   - [...]
;;;   - rfc 3920 
;;;   - rfc 3921
;;;
;;;  bugs and/or improvements
;;;   - start & stop functions for multiple sessions
;;;   - pubsub (XEP-0060) & group chats (XEP-0045)
;;;   - 'send' using call/cc & parameterize'd i/o ports
;;;   - coroutines for sasl negotiation
;;;   - read-async & repsonse-handler
;;;   - ssax:xml->sxml or lazy:xml->sxml
;;;   - default handlers
;;;   - syntax for defining sxpath based handlers
;;;   - improve parsing
;;;   - chatbot exmples
;;;   
#lang racket/base

(require racket/list
	 racket/dict
	 mzlib/os			 ;; hostname
	 srfi/13                         ;; jid decoding
         (planet lizorkin/sxml:2:1/sxml) ;; encoding xml
	 (planet lizorkin/ssax:2:0/ssax) ;; decoding xml
	 "utils.rkt")
			 
(provide (all-defined-out))

;;;;;; ; ; ;      ;   ;; ;;;;;; ;
;;
;; XMPP stanzas
;;
;;;;;;;;;; ;;;  ;  ;;   ;  ;

;; intialization
(define (xmpp-stream host) 
  (string-append "<?xml version='1.0'?>" ;; version='1.0' is a MUST for SASL on 5222 but NOT for ssl on 5223
                 "<stream:stream xmlns:stream='http://etherx.jabber.org/streams' to='" 
                 host 
                 "' xmlns='jabber:client' >")) 

;; authentication
(define (xmpp-auth username password resource)
  (ssxml `(iq (@ (type "set") (id "auth")) 
              (query (@ (xmlns "jabber:iq:auth")) 
                     (username ,username) 
                     (password ,password)
                     (resource ,resource)))))

(define (xmpp-session host)
  (ssxml `(iq (@ (to ,host) (type "set") (id "session")) 
              (session (@ (xmlns "urn:ietf:params:xml:ns:xmpp-session")))))) 

;; messages
(define (message to body)
  (ssxml `(message (@ (to ,to)) (body ,body))))

; presence
(define (presence #:from (from "")
                  #:to (to "") 
                  #:type (type "") 
                  #:show (show "") 
                  #:status (status ""))
  (cond ((not (string=? status ""))
         (ssxml `(presence (@ (type "probe")) (status ,status))))
        ((string=? type "") "<presence/>")
        (else (ssxml `(presence (@ (type ,type)))))))

;; queries
(define (iq body 
            #:from (from "")
            #:to (to "") 
            #:type (type "") 
            #:id (id ""))
  (ssxml `(iq (@ (to ,to) (type ,type) ,body))))

;; curried stanza disection (sxml stanza -> string)
(define ((sxpath-element xpath (ns "")) stanza) 
  (let ((node ((sxpath xpath (list (cons 'ns ns))) stanza)))
    (if (empty? node) "" (car node))))

;; message 
(define message-from (sxpath-element "message/@from/text()"))
(define message-to (sxpath-element "message/@to/text()"))
(define message-id (sxpath-element "message/@id/text()"))
(define message-type (sxpath-element "message/@type/text()"))
(define message-body (sxpath-element "message/body/text()"))
(define message-subject (sxpath-element "message/subject/text()"))

;; info/query
(define iq-type (sxpath-element "iq/@type/text()"))
(define iq-id (sxpath-element "iq/@id/text()"))
(define iq-error-type (sxpath-element "iq/error/@type/text()"))
(define iq-error-text (sxpath-element "iq/error/text()"))
(define iq-error (sxpath-element "iq/error"))

;; presence
(define presence-show (sxpath-element "presence/show/text()"))
(define presence-from (sxpath-element "presence/@from/text()"))
(define presence-status (sxpath-element "presence/status/text()"))


;;;;;;;;;; ; ;     ;  ;;  ;
;;
;; rosters
;;
;;;;;; ; ;;  ;

;; request the roster from server
(define (request-roster from)
  (ssxml `(iq (@ (from ,from) (type "get") (id "roster_1")) 
              (query (@ (xmlns "jabber:iq:roster"))))))

;; add an item to the roster 
(define (add-to-roster from jid name group)
  (ssxml `(iq (@ (from ,from) (type "set") (id "roster_2")) 
              (query (@ (xmlns "jabber:iq:roster"))
                     (item (@ (jid ,jid) (name ,name))
                           (group ,group)))))) 

;; update an item in the roster 
(define (update-roster from jid name group)
  (ssxml `(iq (@ (from ,from) (type "set") (id "roster_3")) 
              (query (@ (xmlns "jabber:iq:roster"))
                     (item (@ (jid ,jid) (name ,name))
                           (group ,group)))))) 

;; remove an item from the roster
(define (remove-from-roster from jid)
  (ssxml `(iq (@ (from ,from) (type "set") (id "roster_4")) 
              (query (@ (xmlns "jabber:iq:roster"))
                     (item (@ (jid ,jid) (subscription "remove"))))))) 


;;;;; ;   ; ;;  ;   ;
;;
;; in-band registration
;;
;;;;;; ;;     ;; ;

(define (reg1)
  (ssxml `(iq (@ (type "get") (id "reg1"))
              (query (@ (xmlns "jabber:iq:register"))))))


;;;;;;;;; ; ;; ; ; ;;  ;;    ;  ;
;;
;; parsing & message/iq/error handlers
;;  - minimal parsing
;;  - handlers match on a tag (eg. 'message)
;;  - handlers are called with a single relevant xmpp stanza 
;;
;;;;;; ;;  ; ; ;;  ;

;; example handlers to print stanzas or their contents
(define (print-message sz)
  (printf "a ~a message from ~a which says '~a.'~%" (message-type sz) (message-from sz) (message-body sz)))

(define (print-iq sz)
  (printf "an iq response of type '~a' with id '~a' error '~a.'~%" (iq-type sz) (iq-id sz) (iq-error-text sz)))

(define (print-presence sz)
  (printf " p-r-e-s-e-n-e-c--> ~a is ~a" (presence-from sz) (presence-status sz)))

(define (print-stanza sz)
  (printf "? ?? -> ~%~a~%" sz))

;; handler to print roster

(define (roster-jids sz) 
  ((sxpath "iq/ns:query/ns:item/@jid/text()" '(( ns . "jabber:iq:roster"))) sz))

(define (roster-items sz)
  ((sxpath-element "iq/ns:query/ns:item"  '(( ns . "jabber:iq:roster"))) sz))

(define (print-roster sz)
  (when (and (string=? (iq-type sz) "result")
             (string=? (iq-id sz) "roster_1"))
    (printf "~a~%" (roster-jids sz))))

;; jid splicing (assuming the jid is in the format user@host/resource)
(define (jid-user jid)
  (string-take jid (string-index jid #\@)))

(define (jid-host jid)
  (let* ((s (string-take-right jid (- (string-length jid) (string-index jid #\@) 1)))
         (v (string-index s #\/)))
    (if v (string-take s v) s )))

(define (jid-resource jid)
  (let ((r (jid-resource-0 jid)))
    (if (void? r) (gethostname) r)))

(define (jid-resource-0 jid)
  (let ((v (string-index jid #\/)))
    (when v (string-take-right jid (- (string-length jid) v 1)))))