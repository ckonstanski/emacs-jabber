;;; jabber-newdisco.el --- caching disco API

;; Copyright (C) 2005, 2008  Magnus Henoch

;; Author: Magnus Henoch <mange@freemail.hu>

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

(require 'jabber-xml)

;;---
;; Keys are ("jid" . "node"), where "node" is nil if appropriate.
;; Values are (identities features), where each identity is ["name"
;; "category" "type"], and each feature is a string.
(defvar jabber-disco-info-cache (make-hash-table :test 'equal))

;; Keys are ("jid" . "node").  Values are (items), where each
;; item is ["name" "jid" "node"] (some values may be nil).
(defvar jabber-disco-items-cache (make-hash-table :test 'equal))

;;; Info

(defun jabber-disco-get-info (jc jid node callback closure-data &optional force)
  "Get disco info for JID and NODE, using connection JC.
Call CALLBACK with JC and CLOSURE-DATA as first and second
arguments and result as third argument when result is available.
On success, result is (IDENTITIES FEATURES), where each identity is [\"name\"
\"category\" \"type\"], and each feature is a string.
On error, result is the error node, recognizable by (eq (car result) 'error).

If CALLBACK is nil, just fetch data.  If FORCE is non-nil,
invalidate cache and get fresh data."
  (when force
    (remhash (cons jid node) jabber-disco-info-cache))
  (let ((result (unless force (jabber-disco-get-info-immediately jid node))))
    (if result
	(and callback (run-with-timer 0 nil callback jc closure-data result))
      (jabber-send-iq jc jid
		      "get"
		      `(query ((xmlns . "http://jabber.org/protocol/disco#info")
			       ,@(when node `((node . ,node)))))
		      #'jabber-disco-got-info (cons callback closure-data)
		      (lambda (jc xml-data callback-data)
			(when (car callback-data)
			  (funcall (car callback-data) jc (cdr callback-data) (jabber-iq-error xml-data))))
		      (cons callback closure-data)))))

(defun jabber-disco-got-info (jc xml-data callback-data)
  (let ((jid (jabber-xml-get-attribute xml-data 'from))
	(node (jabber-xml-get-attribute (jabber-iq-query xml-data)
					'node))
	(result (jabber-disco-parse-info xml-data)))
    (puthash (cons jid node) result jabber-disco-info-cache)
    (when (car callback-data)
      (funcall (car callback-data) jc (cdr callback-data) result))))

(defun jabber-disco-parse-info (xml-data)
  "Extract data from an <iq/> stanza containing a disco#info result.
See `jabber-disco-get-info' for a description of the return value."
  (list
   (mapcar 
    #'(lambda (id)
	(vector (jabber-xml-get-attribute id 'name)
		(jabber-xml-get-attribute id 'category)
		(jabber-xml-get-attribute id 'type)))
    (jabber-xml-get-children (jabber-iq-query xml-data) 'identity))
   (mapcar
    #'(lambda (feature)
	(jabber-xml-get-attribute feature 'var))
    (jabber-xml-get-children (jabber-iq-query xml-data) 'feature))))

(defun jabber-disco-get-info-immediately (jid node)
  "Get cached disco info for JID and NODE.
Return nil if no info available.

Fill the cache with `jabber-disco-get-info'."
  (or
   ;; Check "normal" cache...
   (gethash (cons jid node) jabber-disco-info-cache)
   ;; And then check Entity Capabilities.
   (and (null node) (jabber-caps-get-cached jid))))

;;; Items

(defun jabber-disco-get-items (jc jid node callback closure-data &optional force)
  "Get disco items for JID and NODE, using connection JC.
Call CALLBACK with JC and CLOSURE-DATA as first and second
arguments and items result as third argument when result is
available.
On success, result is a list of items, where each
item is [\"name\" \"jid\" \"node\"] (some values may be nil).
On error, result is the error node, recognizable by (eq (car result) 'error).

If CALLBACK is nil, just fetch data.  If FORCE is non-nil,
invalidate cache and get fresh data."
  (when force
    (remhash (cons jid node) jabber-disco-items-cache))
  (let ((result (gethash (cons jid node) jabber-disco-items-cache)))
    (if result
	(and callback (run-with-timer 0 nil callback jc closure-data result))
      (jabber-send-iq jc jid
		      "get"
		      `(query ((xmlns . "http://jabber.org/protocol/disco#items")
			       ,@(when node `((node . ,node)))))
		      #'jabber-disco-got-items (cons callback closure-data)
		      (lambda (jc xml-data callback-data)
			(when (car callback-data)
			  (funcall (car callback-data) jc (cdr callback-data) (jabber-iq-error xml-data))))
		      (cons callback closure-data)))))

(defun jabber-disco-got-items (jc xml-data callback-data)
  (let ((jid (jabber-xml-get-attribute xml-data 'from))
	(node (jabber-xml-get-attribute (jabber-iq-query xml-data)
					'node))
	(result
	 (mapcar
	  #'(lambda (item)
	      (vector
	       (jabber-xml-get-attribute item 'name)
	       (jabber-xml-get-attribute item 'jid)
	       (jabber-xml-get-attribute item 'node)))
	  (jabber-xml-get-children (jabber-iq-query xml-data) 'item))))
    (puthash (cons jid node) result jabber-disco-items-cache)
    (when (car callback-data)
      (funcall (car callback-data) jc (cdr callback-data) result))))

(defun jabber-disco-get-items-immediately (jid node)
  (gethash (cons jid node) jabber-disco-items-cache))

;;; Publish

(defun jabber-disco-publish (jc node item-name item-jid item-node)
  "Publish the given item under disco node NODE."
  (jabber-send-iq jc nil
		  "set"
		  `(query ((xmlns . "http://jabber.org/protocol/disco#items")
			   ,@(when node `((node . ,node))))
			  (item ((action . "update")
				 (jid . ,item-jid)
				 ,@(when item-name
				     `((name . ,item-name)))
				 ,@(when item-node
				     `((node . ,item-node))))))
		  'jabber-report-success "Disco publish"
		  'jabber-report-success "Disco publish"))

(defun jabber-disco-publish-remove (jc node item-jid item-node)
  "Remove the given item from published disco items."
  (jabber-send-iq jc nil
		  "set"
		  `(query ((xmlns . "http://jabber.org/protocol/disco#items")
			   ,@(when node `((node . ,node))))
			  (item ((action . "remove")
				 (jid . ,item-jid)
				 ,@(when item-node
				     `((node . ,item-node))))))
		  'jabber-report-success "Disco removal"
		  'jabber-report-success "Disco removal"))

;;; Entity Capabilities (XEP-0115)

;;;###autoload
(eval-after-load "jabber-core"
  '(add-to-list 'jabber-presence-chain #'jabber-process-caps))

(defvar jabber-caps-cache (make-hash-table :test 'equal))

(defconst jabber-caps-hash-names
  '(("sha-1" . sha1)
    ("sha-224" . sha224)
    ("sha-256" . sha256)
    ("sha-384" . sha384)
    ("sha-512" . sha512))
  "Hash function name map.
Maps names defined in http://www.iana.org/assignments/hash-function-text-names
to symbols accepted by `secure-hash'.

XEP-0115 currently recommends SHA-1, but let's be future-proof.")

(defun jabber-caps-get-cached (jid)
  "Get disco info from Entity Capabilities cache.
JID should be a string containing a full JID.
Return (IDENTITIES FEATURES), or nil if not in cache."
  (let* ((symbol (jabber-jid-symbol jid))
	 (resource (or (jabber-jid-resource jid) ""))
	 (resource-plist (cdr (assoc resource (get symbol 'resources))))
	 (key (plist-get resource-plist 'caps)))
    (when key
      (let ((cache-entry (gethash key jabber-caps-cache)))
	(when (and (consp cache-entry) (not (floatp (car cache-entry))))
	  cache-entry)))))

;;;###autoload
(defun jabber-process-caps (jc xml-data)
  "Look for entity capabilities in presence stanzas."
  (let* ((from (jabber-xml-get-attribute xml-data 'from))
	 (c (jabber-xml-path xml-data '(("http://jabber.org/protocol/caps" . "c")))))
    (when c
      (jabber-xml-let-attributes
	  (ext hash node ver) c
	(cond
	 (hash
	  ;; If the <c/> element has a hash attribute, it follows the
	  ;; "modern" version of XEP-0115.
	  (jabber-process-caps-modern jc from hash node ver))
	 (t
	  ;; No hash attribute.  Use legacy version of XEP-0115.
	  ;; TODO: do something clever here.
	  ))))))

(defun jabber-process-caps-modern (jc jid hash node ver)
  (when (assoc hash jabber-caps-hash-names)
    ;; We support the hash function used.
    (let* ((key (cons hash ver))
	   (cache-entry (gethash key jabber-caps-cache)))
      ;; Remember the hash in the JID symbol.
      (let* ((symbol (jabber-jid-symbol jid))
	     (resource (or (jabber-jid-resource jid) ""))
	     (resource-entry (assoc resource (get symbol 'resources)))
	     (new-resource-plist (plist-put (cdr resource-entry) 'caps key)))
	(if resource-entry
	    (setf (cdr resource-entry) new-resource-plist)
	  (push (cons resource new-resource-plist) (get symbol 'resources))))
	
      (flet ((request-disco-info
	      ()
	      (jabber-send-iq
	       jc jid
	       "get"
	       `(query ((xmlns . "http://jabber.org/protocol/disco#info")
			(node . ,(concat node "#" ver))))
	       #'jabber-process-caps-info-result (list hash node ver)
	       #'jabber-process-caps-info-error (list hash node ver))))
	(cond
	 ((and (consp cache-entry)
	       (floatp (car cache-entry)))
	  ;; We have a record of asking someone about this hash.
	  (if (< (- (float-time) (car cache-entry)) 10.0)
	      ;; We asked someone about this hash less than 10 seconds ago.
	      ;; Let's add the new JID to the entry, just in case that
	      ;; doesn't work out.
	      (pushnew jid (cdr cache-entry) :test #'string=)
	    ;; We asked someone about it more than 10 seconds ago.
	    ;; They're probably not going to answer.  Let's ask
	    ;; this contact about it instead.
	    (setf (car cache-entry) (float-time))
	    (request-disco-info)))
	 ((null cache-entry)
	  ;; We know nothing about this hash.  Let's note the
	  ;; fact that we tried to get information about it.
	  (puthash key (list (float-time)) jabber-caps-cache)
	  (request-disco-info))
	 (t
	  ;; We already know what this hash represents, so we
	  ;; can cache info for this contact.
	  (puthash (cons jid nil) cache-entry jabber-disco-info-cache)))))))

(defun jabber-process-caps-info-result (jc xml-data closure-data)
  (destructuring-bind (hash node ver) closure-data
    (let* ((key (cons hash ver))
	   (query (jabber-iq-query xml-data))
	   (verification-string (jabber-caps-ver-string query hash)))
      (if (string= ver verification-string)
	  ;; The hash is correct; save info.
	  (puthash key (jabber-disco-parse-info xml-data) jabber-caps-cache)
	;; The hash is incorrect.
	(jabber-caps-try-next jc hash node ver)))))

(defun jabber-process-caps-info-error (jc xml-data closure-data)
  (destructuring-bind (hash node ver) closure-data
    (jabber-caps-try-next jc hash node ver)))

(defun jabber-caps-try-next (jc hash node ver)
  (let* ((key (cons hash ver))
	 (cache-entry (gethash key jabber-caps-cache)))
    (when (floatp (car-safe cache-entry))
      (let ((next-jid (pop (cdr cache-entry))))
	;; Do we know someone else we could ask about this hash?
	(if next-jid
	    (progn
	      (setf (car cache-entry) (float-time))
	      (jabber-send-iq
	       jc next-jid
	       "get"
	       `(query ((xmlns . "http://jabber.org/protocol/disco#info")
			(node . ,(concat node "#" ver))))
	       #'jabber-process-caps-info-result key
	       #'jabber-process-caps-info-error key))
	  ;; No, forget about it for now.
	  (remhash key jabber-caps-cache))))))

(defun jabber-caps-ver-string (query hash)
  ;; XEP-0115, section 5.1
  ;; 1. Initialize an empty string S.
  (with-temp-buffer
    (let* ((identities (jabber-xml-get-children query 'identity))
	   (features (mapcar (lambda (feature) (jabber-xml-get-attribute feature 'var))
			     (jabber-xml-get-children query 'feature)))
	   (maybe-forms (jabber-xml-get-children query 'x))
	   (forms (remove-if-not
		   (lambda (x)
		     ;; Keep elements that are forms and have a FORM_TYPE,
		     ;; according to XEP-0128.
		     (and (string= (jabber-xml-get-xmlns x) "jabber:x:data")
			  (jabber-xdata-formtype x)))
		   maybe-forms)))
      ;; 2. Sort the service discovery identities [15] by category
      ;; and then by type and then by xml:lang (if it exists),
      ;; formatted as CATEGORY '/' [TYPE] '/' [LANG] '/'
      ;; [NAME]. [16] Note that each slash is included even if the
      ;; LANG or NAME is not included (in accordance with XEP-0030,
      ;; the category and type MUST be included.
      (setq identities (sort identities #'jabber-caps-identity-<))
      ;; 3. For each identity, append the 'category/type/lang/name' to
      ;; S, followed by the '<' character.
      (dolist (identity identities)
	(jabber-xml-let-attributes (category type xml:lang name) identity
	  ;; Use `concat' here instead of passing everything to
	  ;; `insert', since `concat' tolerates nil values.
	  (insert (concat category "/" type "/" xml:lang "/" name "<"))))
      ;; 4. Sort the supported service discovery features. [17]
      (setq features (sort features #'string<))
      ;; 5. For each feature, append the feature to S, followed by the
      ;; '<' character.
      (dolist (feature features)
	(insert feature "<"))
      ;; 6. If the service discovery information response includes
      ;; XEP-0128 data forms, sort the forms by the FORM_TYPE (i.e.,
      ;; by the XML character data of the <value/> element).
      (setq forms (sort forms (lambda (a b)
				(string< (jabber-xdata-formtype a)
					 (jabber-xdata-formtype b)))))
      ;; 7. For each extended service discovery information form:
      (dolist (form forms)
	;; Append the XML character data of the FORM_TYPE field's
	;; <value/> element, followed by the '<' character.
	(insert (jabber-xdata-formtype form) "<")
	;; Sort the fields by the value of the "var" attribute.
	(let ((fields (sort (jabber-xml-get-children form 'field)
			    (lambda (a b)
			      (string< (jabber-xml-get-attribute a 'var)
				       (jabber-xml-get-attribute b 'var))))))
	  (dolist (field fields)
	    ;; For each field other than FORM_TYPE:
	    (unless (string= (jabber-xml-get-attribute field 'var) "FORM_TYPE")
	      ;; Append the value of the "var" attribute, followed by the '<' character.
	      (insert (jabber-xml-get-attribute field 'var) "<")
	      ;; Sort values by the XML character data of the <value/> element.
	      (let ((values (sort (mapcar (lambda (value)
					    (car (jabber-xml-node-children value)))
					  (jabber-xml-get-children field 'value))
				  #'string<)))
		;; For each <value/> element, append the XML character
		;; data, followed by the '<' character.
		(dolist (value values)
		  (insert value "<"))))))))

    ;; 8. Ensure that S is encoded according to the UTF-8 encoding
    ;; (RFC 3269 [18]).
    (let ((s (encode-coding-string (buffer-string) 'utf-8 t))
	  (algorithm (cdr (assoc hash jabber-caps-hash-names))))
      ;; 9. Compute the verification string by hashing S using the
      ;; algorithm specified in the 'hash' attribute (e.g., SHA-1 as
      ;; defined in RFC 3174 [19]). The hashed data MUST be generated
      ;; with binary output and encoded using Base64 as specified in
      ;; Section 4 of RFC 4648 [20] (note: the Base64 output MUST NOT
      ;; include whitespace and MUST set padding bits to zero). [21]
      (base64-encode-string (secure-hash algorithm s nil nil t) t))))

(defun jabber-caps-identity-< (a b)
  (let ((a-category (jabber-xml-get-attribute a 'category))
	(b-category (jabber-xml-get-attribute b 'category)))
    (or (string< a-category b-category)
	(and (string= a-category b-category)
	     (let ((a-type (jabber-xml-get-attribute a 'type))
		   (b-type (jabber-xml-get-attribute b 'type)))
	       (or (string< a-type b-type)
		   (and (string= a-type b-type)
			(let ((a-xml:lang (jabber-xml-get-attribute a 'xml:lang))
			      (b-xml:lang (jabber-xml-get-attribute b 'xml:lang)))
			  (string< a-xml:lang b-xml:lang)))))))))


(provide 'jabber-newdisco)

;; arch-tag: b47c06aa-cae6-11d9-b1c0-000a95c2fcd0
