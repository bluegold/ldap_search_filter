;;;; test/test_ldap_filter.lisp — Unit tests for ldap_filter.lisp

(load (merge-pathnames "../ldap_filter.lisp"
                       (make-pathname :directory (pathname-directory *load-truename*)
                                      :name nil :type nil)))

(defvar *pass* 0)
(defvar *fail* 0)

(defmacro check (desc expected actual)
  `(let ((e ,expected) (a ,actual))
     (if (equal e a)
         (incf *pass*)
         (progn
           (incf *fail*)
           (format t "FAIL: ~a~%  expected: ~s~%  got:      ~s~%" ,desc e a)))))

(defmacro check-true (desc form)
  `(if ,form
       (incf *pass*)
       (progn
         (incf *fail*)
         (format t "FAIL: ~a (expected true)~%" ,desc))))

(defmacro check-false (desc form)
  `(if (not ,form)
       (incf *pass*)
       (progn
         (incf *fail*)
         (format t "FAIL: ~a (expected false)~%" ,desc))))

;;; ---- Parser tests -----------------------------------------------------------

(let ((f (parse-filter "(host=www.*)")))
  (check-true  "wildcard: is filter-item"     (filter-item-p f))
  (check       "wildcard: attr"    "host"      (filter-item-attr f))
  (check       "wildcard: op"      "="         (filter-item-op f))
  (check-true  "wildcard: has wildcard"        (wildcard-pattern-p (filter-item-wildcard f))))

(let ((f (parse-filter "(host=*)")))
  (check-true  "presence: is filter-item"     (filter-item-p f))
  (check       "presence: value"   "*"         (filter-item-value f))
  (check-true  "presence: no wildcard"         (null (filter-item-wildcard f))))

(let ((f (parse-filter "(&(host=a)(status=200))")))
  (check-true  "and: is filter-and"           (filter-and-p f))
  (check       "and: node count"  2           (length (filter-and-nodes f))))

(let ((f (parse-filter "(|(host=a)(host=b))")))
  (check-true  "or: is filter-or"             (filter-or-p f))
  (check       "or: node count"   2           (length (filter-or-nodes f))))

(let ((f (parse-filter "(!(host=a))")))
  (check-true  "not: is filter-not"           (filter-not-p f)))

(let ((f (parse-filter "(status>=200)")))
  (check       "ge: op"    ">="               (filter-item-op f))
  (check       "ge: attr"  "status"           (filter-item-attr f)))

(let ((f (parse-filter "(name~=john)")))
  (check       "approx: op" "~="              (filter-item-op f)))

;;; ---- Evaluator tests -------------------------------------------------------

(let ((f (parse-filter "(&(host=www.*)(status=200))")))
  (check-true  "and match"   (filter-match f '(("host" . "www.example.com") ("status" . "200"))))
  (check-false "and no match" (filter-match f '(("host" . "www.example.com") ("status" . "404")))))

(let ((f (parse-filter "(host=*)")))
  (check-true  "presence match"    (filter-match f '(("host" . "x"))))
  (check-false "presence no match" (filter-match f '(("other" . "x")))))

(let ((f (parse-filter "(host=example.com)")))
  (check-true  "exact match"    (filter-match f '(("host" . "example.com"))))
  (check-false "exact no match" (filter-match f '(("host" . "example.org")))))

(let ((f (parse-filter "(host=foo*)")))
  (check-true  "trailing wildcard match"    (filter-match f '(("host" . "foobar"))))
  (check-false "trailing wildcard no match" (filter-match f '(("host" . "barfoo")))))

(let ((f (parse-filter "(host=*bar)")))
  (check-true  "leading wildcard match"    (filter-match f '(("host" . "foobar"))))
  (check-false "leading wildcard no match" (filter-match f '(("host" . "barfoo")))))

(let ((f (parse-filter "(host=*oo*)")))
  (check-true  "mid wildcard match"    (filter-match f '(("host" . "foobar"))))
  (check-false "mid wildcard no match" (filter-match f '(("host" . "bar")))))

(let ((f (parse-filter "(!(host=a))")))
  (check-true  "not match"    (filter-match f '(("host" . "b"))))
  (check-false "not no match" (filter-match f '(("host" . "a")))))

(let ((f (parse-filter "(status>=200)")))
  (check-true  "ge match"    (filter-match f '(("status" . "200"))))
  (check-false "ge no match" (filter-match f '(("status" . "100")))))

(let ((f (parse-filter "(status<=200)")))
  (check-true  "le match"    (filter-match f '(("status" . "200"))))
  (check-false "le no match" (filter-match f '(("status" . "300")))))

(let ((f (parse-filter "(name~=john)")))
  (check-true  "approx match"    (filter-match f '(("name" . "jonn"))))
  (check-false "approx no match" (filter-match f '(("name" . "smith")))))

;;; ---- LTSV tests ------------------------------------------------------------

(let ((attrs (parse-ltsv-line (concatenate 'string "host:example.com" (string #\Tab) "status:200"))))
  (check "ltsv host"   "example.com" (cdr (assoc "host"   attrs :test #'string=)))
  (check "ltsv status" "200"         (cdr (assoc "status" attrs :test #'string=))))

(let ((attrs (parse-ltsv-line "key:val\\nue")))
  (check "ltsv newline escape"
         (coerce (list #\v #\a #\l #\Newline #\u #\e) 'string)
         (cdr (assoc "key" attrs :test #'string=))))

(let ((attrs (parse-ltsv-line "empty:")))
  (check "ltsv empty value" nil (cdr (assoc "empty" attrs :test #'string=))))

;;; ---- CSV tests -------------------------------------------------------------

(check "csv simple"      '("a" "b" "c")   (parse-csv-line "a,b,c"))
(check "csv quoted"      '("a,b" "c")     (parse-csv-line "\"a,b\",c"))
(check "csv dquote"      '("a\"b" "c")    (parse-csv-line "\"a\"\"b\",c"))
(check "csv empty field" '("a" "" "c")    (parse-csv-line "a,,c"))

;;; ---- Output formatting tests -----------------------------------------------

(let ((attrs '(("host" . "example.com") ("status" . "200"))))
  (check "inspect symbol keys"
         "{host: \"example.com\", status: \"200\"}"
         (with-output-to-string (s)
           (write-char #\{ s)
           (loop for (k . v) in attrs for i from 0 do
             (when (plusp i) (write-string ", " s))
             (write-key k s)
             (write-value v s))
           (write-char #\} s))))

(let ((attrs '(("key-with-dash" . "val"))))
  (check "inspect non-symbol key"
         "{\"key-with-dash\" => \"val\"}"
         (with-output-to-string (s)
           (write-char #\{ s)
           (write-key "key-with-dash" s)
           (write-value "val" s)
           (write-char #\} s))))

(check "format nil value" "nil" (with-output-to-string (s) (write-value nil s)))

;;; ---- Wildcard matching tests -----------------------------------------------

(check-true "wc trailing" (wildcard-matches-p (make-wildcard-pattern #("abc" "") nil t) "abcXYZ"))
(check-false "wc trailing fail" (wildcard-matches-p (make-wildcard-pattern #("abc" "") nil t) "XYZabc"))
(check-true "wc leading" (wildcard-matches-p (make-wildcard-pattern #("" "abc") t nil) "XYZabc"))
(check-false "wc leading fail" (wildcard-matches-p (make-wildcard-pattern #("" "abc") t nil) "abcXYZ"))
(check-true "wc all stars" (wildcard-matches-p (make-wildcard-pattern #("" "") t t) "anything"))

;;; ---- Levenshtein tests -----------------------------------------------------

(check-true  "levenshtein same"    (levenshtein-lte "abc" "abc" 2))
(check-true  "levenshtein near"    (levenshtein-lte "abc" "ab"  2))
(check-false "levenshtein far"     (levenshtein-lte "abc" "xyz" 2))

;;; ---- Report -----------------------------------------------------------------

(format t "~&~d passed, ~d failed~%" *pass* *fail*)
(sb-ext:exit :code (if (= *fail* 0) 0 1))
