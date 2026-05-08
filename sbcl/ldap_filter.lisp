;;;; ldap_filter.lisp — SBCL implementation of RFC 4515 LDAP Search Filter

(declaim (optimize (speed 3) (safety 1) (debug 0)))

;;;; ---- Timing ----------------------------------------------------------------

(defvar *start-time* 0
  "Process start time set at the top of MAIN, in internal real-time units.")

(defun elapsed-ns ()
  (* (- (get-internal-real-time) *start-time*)
     (floor 1000000000 internal-time-units-per-second)))

(defun emit-phase (phase stream)
  (let ((ns (elapsed-ns)))
    (format stream "phase=~a t=~d elapsed_ns=~d~%" phase ns ns)
    (finish-output stream)))

;;;; ---- Error condition -------------------------------------------------------

(define-condition ldap-parse-error (error)
  ((message :initarg :message :reader ldap-parse-error-message))
  (:report (lambda (c s) (write-string (ldap-parse-error-message c) s))))

(defun parse-fail (msg)
  (error 'ldap-parse-error :message msg))

;;;; ---- AST nodes -------------------------------------------------------------

(defstruct (filter-and (:constructor make-filter-and (nodes))) nodes)
(defstruct (filter-or  (:constructor make-filter-or  (nodes))) nodes)
(defstruct (filter-not (:constructor make-filter-not (node)))  node)
(defstruct (wildcard-pattern (:constructor make-wildcard-pattern (parts leading trailing)))
  parts leading trailing)
(defstruct (filter-item (:constructor make-filter-item (attr op value wildcard)))
  attr op value wildcard)

;;;; ---- Hex decode ------------------------------------------------------------

(defun hex-digit (c)
  (cond ((char<= #\0 c #\9) (- (char-code c) 48))
        ((char<= #\a c #\f) (+ 10 (- (char-code c) 97)))
        ((char<= #\A c #\F) (+ 10 (- (char-code c) 65)))
        (t nil)))

(defun decode-hex-char (h l)
  (let ((hi (hex-digit h)) (lo (hex-digit l)))
    (and hi lo (code-char (logior (ash hi 4) lo)))))

;;;; ---- Value parsing --------------------------------------------------------

(defun parse-item-value (raw)
  "Returns (values decoded-string wildcard-or-nil)"
  (when (string= raw "*")
    (return-from parse-item-value (values "*" nil)))
  ;; Use string output streams; get-output-stream-string always returns a fresh string.
  (let ((decoded  (make-string-output-stream))
        (seg      (make-string-output-stream))
        (segments nil)
        (saw-star nil)
        (i 0) (n (length raw)))
    (loop while (< i n) do
      (let ((c (char raw i)))
        (cond
          ((char= c #\\)
           (when (>= (+ i 2) n)
             (parse-fail "incomplete escape sequence"))
           (let ((dc (decode-hex-char (char raw (+ i 1)) (char raw (+ i 2)))))
             (unless dc (parse-fail "invalid escape sequence"))
             (write-char dc decoded)
             (write-char dc seg)
             (incf i 3)))
          ((char= c #\*)
           (setf saw-star t)
           (write-char #\* decoded)
           (push (get-output-stream-string seg) segments)  ; resets seg
           (incf i))
          (t
           (write-char c decoded)
           (write-char c seg)
           (incf i)))))
    (let ((dstr (get-output-stream-string decoded)))
      (if (not saw-star)
          (values dstr nil)
          (progn
            (push (get-output-stream-string seg) segments)  ; final segment after last *
            (values dstr
                    (make-wildcard-pattern
                     (coerce (nreverse segments) 'vector)
                     (char= (char raw 0) #\*)
                     (char= (char raw (1- n)) #\*))))))))

;;;; ---- Forward declarations ------------------------------------------------

(declaim (ftype (function (t) t) parse-filter-content))
(declaim (ftype (function (t t) t) item-match))

;;;; ---- Item parsing ---------------------------------------------------------

(defun find-op (content)
  "Returns (values op-start op-string) or (values nil nil)"
  (let ((n (length content)))
    (loop for i from 0 below n do
      (let ((c (char content i)))
        (cond
          ((char= c #\=) (return-from find-op (values i "=")))
          ((member c '(#\~ #\> #\<) :test #'char=)
           (if (and (< (1+ i) n) (char= (char content (1+ i)) #\=))
               (return-from find-op (values i (coerce (list c #\=) 'string)))
               (return-from find-op (values nil nil)))))))
    (values nil nil)))

(defun parse-item (content)
  (multiple-value-bind (op-start op) (find-op content)
    (unless op-start (parse-fail "error in item syntax"))
    (let ((attr (subseq content 0 op-start)))
      (when (string= attr "") (parse-fail "error in item syntax"))
      (let ((raw-value (subseq content (+ op-start (length op)))))
        (multiple-value-bind (value wildcard) (parse-item-value raw-value)
          (make-filter-item attr op value wildcard))))))

;;;; ---- Filter parsing -------------------------------------------------------

(defun parse-filter-at (expr pos)
  "Returns (values node next-pos)"
  (when (or (>= pos (length expr)) (char/= (char expr pos) #\())
    (parse-fail "expected '('"))
  (let ((depth 0) (end -1) (n (length expr)))
    (loop for i from pos below n
          while (< end 0) do
      (case (char expr i)
        (#\( (incf depth))
        (#\) (decf depth)
             (when (< depth 0) (parse-fail "parenthesis mismatch"))
             (when (= depth 0) (setf end i)))))
    (when (< end 0) (parse-fail "parenthesis mismatch"))
    (values (parse-filter-content (subseq expr (1+ pos) end))
            (1+ end))))

(defun parse-filter-list (expr pos)
  "Returns (values nodes end-pos)"
  (let ((nodes nil) (n (length expr)))
    (loop while (and (< pos n) (char= (char expr pos) #\()) do
      (multiple-value-bind (node next) (parse-filter-at expr pos)
        (push node nodes)
        (setf pos next)))
    (values (nreverse nodes) pos)))

(defun parse-filter-content (content)
  (when (= (length content) 0) (parse-fail "empty filter"))
  (case (char content 0)
    (#\&
     (multiple-value-bind (nodes _) (parse-filter-list content 1)
       (declare (ignore _))
       (when (null nodes) (parse-fail "expected at least one nested filter"))
       (make-filter-and nodes)))
    (#\|
     (multiple-value-bind (nodes _) (parse-filter-list content 1)
       (declare (ignore _))
       (when (null nodes) (parse-fail "expected at least one nested filter"))
       (make-filter-or nodes)))
    (#\!
     (multiple-value-bind (node next) (parse-filter-at content 1)
       (when (< next (length content))
         (parse-fail "not operator has more than one filter"))
       (make-filter-not node)))
    (t (parse-item content))))

(defun parse-filter (expr)
  (multiple-value-bind (node next) (parse-filter-at expr 0)
    (unless (= next (length expr)) (parse-fail "unexpected trailing input"))
    node))

;;;; ---- Attrs (ordered alist) ------------------------------------------------

(defun attrs-get (attrs key)
  "Returns (values value found-p)"
  (let ((pair (assoc key attrs :test #'string=)))
    (if pair (values (cdr pair) t) (values nil nil))))

;;;; ---- Wildcard matching ----------------------------------------------------

(defun wildcard-matches-p (pattern actual)
  (let* ((parts    (wildcard-pattern-parts pattern))
         (leading  (wildcard-pattern-leading pattern))
         (trailing (wildcard-pattern-trailing pattern))
         (non-empty (remove "" (coerce parts 'list) :test #'string=)))
    (when (null non-empty) (return-from wildcard-matches-p t))
    (let ((pos  0)
          (al   (length actual))
          (last (1- (length non-empty))))
      (loop for i from 0 for part in non-empty do
        (let ((pl (length part)))
          (cond
            ((and (= i 0) (not leading))
             (unless (and (<= pl (- al pos))
                          (string= actual part :start1 pos :end1 (+ pos pl)))
               (return-from wildcard-matches-p nil))
             (incf pos pl))
            ((and (= i last) (not trailing))
             (return-from wildcard-matches-p
               (and (<= (+ pos pl) al)
                    (string= actual part :start1 (- al pl) :end1 al))))
            (t
             (let ((found (search part actual :start2 pos)))
               (unless found (return-from wildcard-matches-p nil))
               (setf pos (+ found pl)))))))
      t)))

;;;; ---- Levenshtein ----------------------------------------------------------

(defun levenshtein-lte (a b max-dist)
  (let* ((la (length a)) (lb (length b)))
    (when (> (abs (- la lb)) max-dist) (return-from levenshtein-lte nil))
    (let ((prev (make-array (1+ lb) :element-type 'fixnum))
          (curr (make-array (1+ lb) :element-type 'fixnum :initial-element 0)))
      (dotimes (j (1+ lb)) (setf (aref prev j) j))
      (dotimes (i la)
        (setf (aref curr 0) (1+ i))
        (let ((row-min (aref curr 0)))
          (dotimes (j lb)
            (let* ((cost (if (char= (char a i) (char b j)) 0 1))
                   (v (min (1+ (aref prev (1+ j)))
                           (1+ (aref curr j))
                           (+ (aref prev j) cost))))
              (setf (aref curr (1+ j)) v)
              (when (< v row-min) (setf row-min v))))
          (when (> row-min max-dist) (return-from levenshtein-lte nil)))
        (rotatef prev curr))
      (<= (aref prev lb) max-dist))))

;;;; ---- Filter evaluation ----------------------------------------------------

(defun filter-match (f attrs)
  (etypecase f
    (filter-and (every (lambda (n) (filter-match n attrs)) (filter-and-nodes f)))
    (filter-or  (some  (lambda (n) (filter-match n attrs)) (filter-or-nodes f)))
    (filter-not (not (filter-match (filter-not-node f) attrs)))
    (filter-item (item-match f attrs))))

(defun item-match (item attrs)
  (let ((op    (filter-item-op    item))
        (attr  (filter-item-attr  item))
        (value (filter-item-value item))
        (wc    (filter-item-wildcard item)))
    (cond
      ((string= op "=")
       (if (string= value "*")
           (nth-value 1 (attrs-get attrs attr))
           (multiple-value-bind (actual found) (attrs-get attrs attr)
             (and found actual
                  (if wc
                      (wildcard-matches-p wc actual)
                      (string= actual value))))))
      (t
       (multiple-value-bind (actual found) (attrs-get attrs attr)
         (and found actual
              (cond
                ((string= op ">=") (string>= actual value))
                ((string= op "<=") (string<= actual value))
                ((string= op "~=") (levenshtein-lte value actual 2)))))))))

;;;; ---- Output formatting ----------------------------------------------------

(defun ruby-symbol-p (key)
  (and (plusp (length key))
       (let ((c (char key 0)))
         (or (char= c #\_) (char<= #\a c #\z) (char<= #\A c #\Z)))
       (every (lambda (c)
                (or (char= c #\_)
                    (char<= #\a c #\z) (char<= #\A c #\Z)
                    (char<= #\0 c #\9)))
              key)))

(defun escape-for-ruby (s out)
  (loop for c across s do
    (case c
      (#\" (write-string "\\\"" out))
      (#\\ (write-string "\\\\" out))
      (#\Newline (write-string "\\n" out))
      (#\Return  (write-string "\\r" out))
      (#\Tab     (write-string "\\t" out))
      (t (write-char c out)))))

(defun write-key (key out)
  (if (ruby-symbol-p key)
      (progn (write-string key out) (write-string ": " out))
      (progn
        (write-char #\" out)
        (escape-for-ruby key out)
        (write-string "\" => " out))))

(defun write-value (v out)
  (if (null v)
      (write-string "nil" out)
      (progn
        (write-char #\" out)
        (escape-for-ruby v out)
        (write-char #\" out))))

(defun write-attrs (attrs out)
  (write-char #\{ out)
  (loop for (k . v) in attrs for i from 0 do
    (when (plusp i) (write-string ", " out))
    (write-key k out)
    (write-value v out))
  (write-char #\} out)
  (write-char #\Newline out))

;;;; ---- LTSV parsing ---------------------------------------------------------

(defun unescape-ltsv (s)
  (when (= (length s) 0) (return-from unescape-ltsv nil))
  (let ((out (make-array (length s) :element-type 'character :fill-pointer 0))
        (i 0) (n (length s)))
    (loop while (< i n) do
      (let ((c (char s i)))
        (cond
          ((char= c #\\)
           (if (>= (1+ i) n)
               (progn (vector-push-extend #\\ out) (incf i))
               (let ((nc (char s (1+ i))))
                 (cond
                   ((char= nc #\r) (vector-push-extend #\Return  out))
                   ((char= nc #\n) (vector-push-extend #\Newline out))
                   ((char= nc #\t) (vector-push-extend #\Tab     out))
                   ((char= nc #\\) (vector-push-extend #\\       out))
                   (t (vector-push-extend #\\ out) (vector-push-extend nc out)))
                 (incf i 2))))
          (t (vector-push-extend c out) (incf i)))))
    (if (= (length out) 0) nil (coerce out 'string))))

(defun split-tabs (s)
  (loop for start = 0 then (1+ (or end (length s)))
        for end   = (position #\Tab s :start start)
        collect (subseq s start (or end (length s)))
        while end))

(defun parse-ltsv-line (line)
  (let ((attrs nil))
    (dolist (entry (split-tabs line))
      (let ((colon (position #\: entry)))
        (when colon
          (push (cons (subseq entry 0 colon)
                      (unescape-ltsv (subseq entry (1+ colon))))
                attrs))))
    (nreverse attrs)))

;;;; ---- CSV parsing ----------------------------------------------------------

(defun parse-csv-line (line)
  (let ((fields nil) (i 0) (n (length line)))
    (flet ((read-field ()
             (cond
               ((and (< i n) (char= (char line i) #\"))
                (incf i)
                (let ((buf (make-array 16 :element-type 'character
                                         :fill-pointer 0 :adjustable t)))
                  (loop
                    (when (>= i n) (return))
                    (let ((c (char line i)))
                      (if (char= c #\")
                          (progn
                            (incf i)
                            (if (and (< i n) (char= (char line i) #\"))
                                (progn (vector-push-extend #\" buf) (incf i))
                                (return)))
                          (progn (vector-push-extend c buf) (incf i)))))
                  (coerce buf 'string)))
               (t
                (let ((start i))
                  (loop while (and (< i n) (char/= (char line i) #\,))
                        do (incf i))
                  (subseq line start i))))))
      (loop
        (push (read-field) fields)
        (if (and (< i n) (char= (char line i) #\,))
            (incf i)
            (return))))
    (nreverse fields)))

(defun strip-bom (s)
  (if (and (plusp (length s)) (char= (char s 0) (code-char #xFEFF)))
      (subseq s 1) s))

(defun row-to-attrs (headers row)
  (loop for key in headers for i from 0
        collect (cons key (if (< i (length row)) (nth i row) ""))))

;;;; ---- Input source (plain file or xz pipe) ---------------------------------

(defstruct (input-source (:constructor make-input-source (stream process)))
  stream process)

(defun ends-with-p (s suffix)
  (let ((sl (length s)) (pl (length suffix)))
    (and (>= sl pl) (string= s suffix :start1 (- sl pl)))))

(defun detect-format (path)
  (let ((lower (string-downcase path)))
    (cond ((or (ends-with-p lower ".csv")  (ends-with-p lower ".csv.xz"))  :csv)
          ((or (ends-with-p lower ".ltsv") (ends-with-p lower ".ltsv.xz")) :ltsv)
          (t :ltsv))))

(defun open-input (path)
  (if (ends-with-p (string-downcase path) ".xz")
      (let* ((proc (sb-ext:run-program "xz" (list "-dc" path)
                                       :search t
                                       :output :stream
                                       :error *error-output*
                                       :external-format :utf-8))
             (stream (sb-ext:process-output proc)))
        (make-input-source stream proc))
      (make-input-source
       (open path :direction :input :external-format :utf-8) nil)))

(defun close-input (src)
  (close (input-source-stream src))
  (when (input-source-process src)
    (sb-ext:process-wait (input-source-process src))))

;;;; ---- Processing -----------------------------------------------------------

(defun process-ltsv (stream filter out)
  (loop for line = (read-line stream nil nil)
        while line do
    (when (and (plusp (length line))
               (char= (char line (1- (length line))) #\Return))
      (setf line (subseq line 0 (1- (length line)))))
    (let ((attrs (parse-ltsv-line line)))
      (when (filter-match filter attrs)
        (write-attrs attrs out)))))

(defun process-csv (stream filter out)
  (let ((header-line (read-line stream nil nil)))
    (unless header-line (return-from process-csv))
    (let ((headers (parse-csv-line (strip-bom header-line))))
      (loop for line = (read-line stream nil nil)
            while line do
        (when (and (plusp (length line))
                   (char= (char line (1- (length line))) #\Return))
          (setf line (subseq line 0 (1- (length line)))))
        (let* ((row   (parse-csv-line line))
               (attrs (row-to-attrs headers row)))
          (when (filter-match filter attrs)
            (write-attrs attrs out)))))))

;;;; ---- Argument parsing -----------------------------------------------------

(defun parse-argv (argv)
  "Returns (values filter-string input-path format-string)"
  (let ((fmt "auto") (filter nil) (input nil) (positional nil) (i 0))
    (loop while (< i (length argv)) do
      (let ((arg (nth i argv)))
        (incf i)
        (cond
          ((string= arg "--format")
           (when (< i (length argv)) (setf fmt (nth i argv)) (incf i)))
          ((string= arg "--filter")
           (when (< i (length argv)) (setf filter (nth i argv)) (incf i)))
          ((string= arg "--input")
           (when (< i (length argv)) (setf input (nth i argv)) (incf i)))
          ((or (string= arg "--jit") (string= arg "--no-jit")
               (string= arg "--yjit") (string= arg "--no-yjit")) nil)
          ((string= arg "--help") nil)
          (t (push arg positional)))))
    (let ((pos (nreverse positional)))
      (when (null filter) (setf filter (first pos)))
      (when (null input)  (setf input  (second pos)))
      (values filter input fmt))))

;;;; ---- Main -----------------------------------------------------------------

(defun run (argv stdout stderr)
  (multiple-value-bind (filter-str input-path fmt-str) (parse-argv argv)
    (unless (and filter-str input-path)
      (error "filter and input path are required"))

    (emit-phase "boot" stderr)

    (let* ((fmt    (cond ((string= fmt-str "csv")  :csv)
                         ((string= fmt-str "ltsv") :ltsv)
                         (t (detect-format input-path))))
           (filter (parse-filter filter-str))
           (src    (open-input input-path)))

      (emit-phase "ready" stderr)

      (unwind-protect
          (progn
            (ecase fmt
              (:csv  (process-csv  (input-source-stream src) filter stdout))
              (:ltsv (process-ltsv (input-source-stream src) filter stdout)))
            (finish-output stdout))
        (close-input src))

      (emit-phase "done" stderr))))

(defun main ()
  (setf *start-time* (get-internal-real-time))
  (handler-case
      (progn
        (run (cdr sb-ext:*posix-argv*) *standard-output* *error-output*)
        (sb-ext:exit :code 0))
    (ldap-parse-error (e)
      (format *error-output* "~a~%" (ldap-parse-error-message e))
      (sb-ext:exit :code 1))
    (error (e)
      (format *error-output* "~a~%" e)
      (sb-ext:exit :code 1))))
