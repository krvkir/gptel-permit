;;; gptel-permit-test.el --- Tests for gptel-permit -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)



(ert-deftest gptel-permit-match-rule ()
  "Test matching rules with various arguments and regular expressions."
  (let ((rule '(:tool "Bash" :conditions ((:command . "^openspec [^&|;]*$")) :action allow)))
    ;; Perfect match
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "openspec foo"))))
                'allow))
    ;; Tool mismatch
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:command "openspec foo"))))))
    ;; Condition mismatch (command has ampersand)
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "openspec foo & bar"))))))
    ;; Missing argument
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:other "args")))))))

  ;; Multi-condition rule
  (let ((rule '(:tool "Read" :conditions ((:file_path . "secret") (:start_line . "^[0-9]+$")) :action deny)))
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/tmp/secret.txt" :start_line 10))))
                'deny))
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/tmp/secret.txt" :start_line "abc"))))))
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/tmp/public.txt" :start_line 10))))))))

(ert-deftest gptel-permit-security-hook ()
  "Test security-hook behavior via rules and prioritization."
  (let ((gptel-permit-rules nil)
        (gptel-permit-global-rules nil))

    ;; 1. Relative path traversal caught by :outside-project predicate
    (let ((gptel-permit-global-rules
           '((:tool-group write :conditions ((path . :path-traversal)) :action ask)))
          (write-traversal (list :name "Write" :args '(:path "/tmp" :filename "../etc/passwd" :content "foo"))))
      (should (equal (gptel-permit--apply-rules write-traversal)
                     '(:confirm t))))

    ;; 2. Absolute path on Write tool filename — caught by ^/ regexp
    (let ((gptel-permit-global-rules
           '((:tool-group write :conditions ((path . :path-traversal)) :action ask)))
          (write-absolute (list :name "Write" :args '(:path "/tmp" :filename "/etc/passwd" :content "foo"))))
      (should (equal (gptel-permit--apply-rules write-absolute)
                     '(:confirm t))))

    ;; 3. Matching Session Rule (allow)
    (let ((gptel-permit-rules
           '((:tool "Read" :conditions ((:file_path . "allowed_doc")) :action allow)))
          (call (list :name "Read" :args '(:file_path "allowed_doc.txt"))))
      (should (equal (gptel-permit--apply-rules call)
                     '(:confirm nil))))

    ;; 4. Matching Global Rule (deny)
    (let ((gptel-permit-global-rules
           '((:tool "Bash" :conditions ((:command . "rm -rf")) :action deny)))
          (call (list :name "Bash" :args '(:command "rm -rf /"))))
      (should (equal (plist-get (gptel-permit--apply-rules call) :block)
                     "auto-denied")))

    ;; 5. Session Rule takes precedence over Global Rule
    (let ((gptel-permit-rules
           '((:tool "Bash" :conditions ((:command . "rm -rf")) :action allow)))
          (gptel-permit-global-rules
           '((:tool "Bash" :conditions ((:command . "rm -rf")) :action deny)))
          (call (list :name "Bash" :args '(:command "rm -rf /"))))
      (should (equal (gptel-permit--apply-rules call)
                     '(:confirm nil))))

    ;; 6. Fallback (no rules match)
    (let ((call (list :name "Read" :args '(:file_path "random.txt"))))
      (should (null (gptel-permit--apply-rules call))))))

(ert-deftest gptel-permit-normalize-tool-call-test ()
  "Test gptel-permit--normalize-tool-call with various structures."
  (let* ((tool (gptel--make-tool-internal :name "Edit" :function 'ignore :description "test tool"))
         ;; Overlay-style tool call: (tool-spec arg-plist process-tool-result)
         (overlay-tc (list tool '(:path "/tmp/foo" :diff t) 'ignore))
         ;; Plist-style tool call: (:name name :args args)
         (plist-tc '(:name "Edit" :args (:path "/tmp/foo" :diff t))))
    ;; 1. Normalizing overlay-style should return plist-style
    (should (equal (gptel-permit--normalize-tool-call overlay-tc)
                   '(:name "Edit" :args (:path "/tmp/foo" :diff t))))
    ;; 2. Normalizing plist-style should return plist-style unchanged
    (should (equal (gptel-permit--normalize-tool-call plist-tc)
                   plist-tc))
    ;; 3. Normalizing non-list or nil should return it as-is
    (should (null (gptel-permit--normalize-tool-call nil)))))

(provide 'gptel-permit-test)
;;; gptel-permit-test.el ends here
