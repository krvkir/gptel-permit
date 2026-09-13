;;; gptel-permit-callable-conditions-test.el --- Tests for callable conditions -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Dispatch: string regexp (unchanged behavior)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-cond-dispatch-string-regexp ()
  "A string condition value is treated as a regexp."
  (should (eq (gptel-permit--match-rule-p
               '(:tool "Bash" :conditions ((:command . "rm")) :action ask)
               (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "rm -rf /tmp/x"))))
              'ask)))

;; -------------------------------------------------------------------
;; Dispatch: keyword predicate (legacy, via alist)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-cond-dispatch-keyword-legacy ()
  "A keyword condition value resolves through the predicate alist."
  ;; `file-in-directory-p' requires the directory to exist, so use a
  ;; real directory rather than a fictional /home/user/.
  (let ((default-directory temporary-file-directory)
        (buffer-file-name (expand-file-name "buf.el" temporary-file-directory)))
    (should (eq (gptel-permit--match-rule-p
                 '(:tool "Read" :conditions ((:file_path . :inside-project)) :action allow)
                 (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "src/x.el"))))
                'allow))
    (should (null (gptel-permit--match-rule-p
                   '(:tool "Read" :conditions ((:file_path . :inside-project)) :action allow)
                   (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/etc/hosts"))))))))

;; -------------------------------------------------------------------
;; Dispatch: custom predicate keyword registered in the alist
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-cond-dispatch-custom-keyword ()
  "A user-registered keyword in the alist is dispatched to its function."
  (let ((gptel-permit--condition-predicates
         (append '((:is-elisp . (lambda (expanded _raw _tc)
                                  (string-suffix-p ".el" expanded))))
                 gptel-permit--condition-predicates))
        (default-directory "/home/user/"))
    (should (eq (gptel-permit--match-rule-p
                 '(:tool "Read" :conditions ((:file_path . :is-elisp)) :action allow)
                 (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "foo.el"))))
                'allow))
    (should (null (gptel-permit--match-rule-p
                   '(:tool "Read" :conditions ((:file_path . :is-elisp)) :action allow)
                   (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "foo.py"))))))))

;; -------------------------------------------------------------------
;; Dispatch: unknown keyword fails (condition does not match)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-cond-dispatch-unknown-keyword ()
  "An unregistered keyword makes the condition fail gracefully."
  (should (null (gptel-permit--match-rule-p
                 '(:tool "Bash" :conditions ((:command . :no-such-pred)) :action allow)
                 (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "ls")))))))

;; -------------------------------------------------------------------
;; Dispatch: function condition receives (value tool-call)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-cond-dispatch-function-receives-value-and-tool-call ()
  "A function condition is called with the arg value and the tool-call plist."
  (let* ((received-value nil)
         (received-tool-call nil)
         (spy (lambda (v tc)
                (setq received-value v
                      received-tool-call tc)
                t)))
    (should (eq (gptel-permit--match-rule-p
                 `(:tool "Bash" :conditions ((:command . ,spy)) :action allow)
                 (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "echo hi"))))
                'allow))
    (should (string= received-value "echo hi"))
    (should (equal (plist-get received-tool-call :name) "Bash"))
    (should (equal (plist-get received-tool-call :args) '(:command "echo hi")))))

;; -------------------------------------------------------------------
;; Short-circuit: first nil stops later conditions from running
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-cond-short-circuits-on-first-nil ()
  "When the first condition returns nil, later condition callables run."
  (let ((first-called nil)
        (second-called nil))
    (gptel-permit--match-rule-p
     `(:tool "Bash"
             :conditions ((:command . ,(lambda (_v _tc)
                                         (setq first-called t)
                                         nil))
                          (:cwd . ,(lambda (_v _tc)
                                     (setq second-called t)
                                     t)))
             :action allow)
     (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "x" :cwd "/tmp"))))
    (should first-called)
    (should (null second-called))))

;; -------------------------------------------------------------------
;; Predicate functions: raw vs expanded
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-cond-path-traversal-uses-raw ()
  "Path-traversal predicate checks the raw (pre-expansion) value."
  (should (eq (gptel-permit--match-rule-p
               '(:tool "Write" :conditions ((:filename . :path-traversal)) :action ask)
               (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "/tmp" :filename "../escape.txt"))))
              'ask)))

(ert-deftest gptel-permit-cond-inside-project-uses-expanded ()
  "Inside-project predicate receives the expanded path."
  (let ((default-directory (temporary-file-directory))
        (buffer-file-name (expand-file-name "dummy.el" temporary-file-directory)))
    (should (eq (gptel-permit--match-rule-p
                 '(:tool "Read" :conditions ((:file_path . :inside-project)) :action allow)
                 (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "inner/x.el"))))
                'allow))))

;; -------------------------------------------------------------------
;; --apply-rules fails closed on internal error
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-apply-rules-fails-closed-on-error ()
  "An error inside rule evaluation returns (:confirm t), not nil."
  (let ((gptel-permit--condition-predicates
         '((:boom . (lambda (&rest _) (error "boom")))))
        (gptel-permit-rules nil)
        (gptel-permit-global-rules
         '((:tool "Bash" :conditions ((:command . :boom)) :action allow))))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm t)))))

(provide 'gptel-permit-callable-conditions-test)
;;; gptel-permit-callable-conditions-test.el ends here
