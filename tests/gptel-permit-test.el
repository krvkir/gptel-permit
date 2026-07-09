;;; gptel-permit-test.el --- Tests for gptel-permit -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

(ert-deftest gptel-permit-normalize-arg ()
  "Test that path arguments are expanded while others are formatted as strings."
  (let ((default-directory "/tmp/"))
    (should (equal (gptel-permit--normalize-arg :path "foo")
                   (expand-file-name "foo" "/tmp/")))
    (should (equal (gptel-permit--normalize-arg :file_path "/usr/bin")
                   "/usr/bin"))
    (should (equal (gptel-permit--normalize-arg :filename "bar.txt")
                   (expand-file-name "bar.txt" "/tmp/")))
    (should (equal (gptel-permit--normalize-arg :command "ls -la")
                   "ls -la"))
    (should (equal (gptel-permit--normalize-arg :line_number 42)
                   "42"))))

(ert-deftest gptel-permit-match-rule ()
  "Test matching rules with various arguments and regular expressions."
  (let ((rule '(:tool "Bash" :conditions ((:command . "^openspec [^&|;]*$")) :action allow)))
    ;; Perfect match
    (should (eq (gptel-permit--match-rule-p rule "Bash" '(:command "openspec foo"))
                'allow))
    ;; Tool mismatch
    (should (null (gptel-permit--match-rule-p rule "Read" '(:command "openspec foo"))))
    ;; Condition mismatch (command has ampersand)
    (should (null (gptel-permit--match-rule-p rule "Bash" '(:command "openspec foo & bar"))))
    ;; Missing argument
    (should (null (gptel-permit--match-rule-p rule "Bash" '(:other "args")))))

  ;; Multi-condition rule
  (let ((rule '(:tool "Read" :conditions ((:file_path . "secret") (:start_line . "^[0-9]+$")) :action deny)))
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "/tmp/secret.txt" :start_line 10))
                'deny))
    (should (null (gptel-permit--match-rule-p rule "Read" '(:file_path "/tmp/secret.txt" :start_line "abc"))))
    (should (null (gptel-permit--match-rule-p rule "Read" '(:file_path "/tmp/public.txt" :start_line 10))))))

(ert-deftest gptel-permit-security-hook ()
  "Test security-hook behavior via rules and prioritization."
  (let ((gptel-permit-rules nil)
        (gptel-permit-global-rules nil))

    ;; 1. Relative path traversal caught by :outside-project predicate
    (let ((gptel-permit-global-rules
           '((:tool-group write :conditions ((:arg-group path . :path-traversal)) :action ask)))
          (write-traversal (list :name "Write" :args '(:path "/tmp" :filename "../etc/passwd" :content "foo"))))
      (should (equal (gptel-permit-pre-tool-security-hook write-traversal)
                     '(:confirm t))))

    ;; 2. Absolute path on Write tool filename — caught by ^/ regexp
    (let ((gptel-permit-global-rules
           '((:tool-group write :conditions ((:arg-group path . :path-traversal)) :action ask)))
          (write-absolute (list :name "Write" :args '(:path "/tmp" :filename "/etc/passwd" :content "foo"))))
      (should (equal (gptel-permit-pre-tool-security-hook write-absolute)
                     '(:confirm t))))

    ;; 3. Matching Session Rule (allow)
    (let ((gptel-permit-rules
           '((:tool "Read" :conditions ((:file_path . "allowed_doc")) :action allow)))
          (call (list :name "Read" :args '(:file_path "allowed_doc.txt"))))
      (should (equal (gptel-permit-pre-tool-security-hook call)
                     '(:confirm nil))))

    ;; 4. Matching Global Rule (deny)
    (let ((gptel-permit-global-rules
           '((:tool "Bash" :conditions ((:command . "rm -rf")) :action deny)))
          (call (list :name "Bash" :args '(:command "rm -rf /"))))
      (should (equal (plist-get (gptel-permit-pre-tool-security-hook call) :block)
                     "Tool Bash execution was auto-denied by user permission rules.")))

    ;; 5. Session Rule takes precedence over Global Rule
    (let ((gptel-permit-rules
           '((:tool "Bash" :conditions ((:command . "rm -rf")) :action allow)))
          (gptel-permit-global-rules
           '((:tool "Bash" :conditions ((:command . "rm -rf")) :action deny)))
          (call (list :name "Bash" :args '(:command "rm -rf /"))))
      (should (equal (gptel-permit-pre-tool-security-hook call)
                     '(:confirm nil))))

    ;; 6. Fallback (no rules match)
    (let ((call (list :name "Read" :args '(:file_path "random.txt"))))
      (should (null (gptel-permit-pre-tool-security-hook call))))))

(ert-deftest gptel-permit-logging-test ()
  "Test that extensive logging is correctly performed when enabled."
  (let ((gptel-permit-log-enabled nil)
        (gptel-permit-rules
         '((:tool "Read" :conditions ((:file_path . "secret")) :action deny)))
        (call (list :name "Read" :args '(:file_path "/tmp/secret.txt"))))
    ;; Ensure log buffer is clean
    (when (get-buffer "*gptel-permit-log*")
      (kill-buffer "*gptel-permit-log*"))

    ;; 1. Logging disabled: nothing should be logged
    (gptel-permit-pre-tool-security-hook call)
    (should (not (get-buffer "*gptel-permit-log*")))

    ;; 2. Logging enabled: logs should be populated
    (setq gptel-permit-log-enabled t)
    (gptel-permit-pre-tool-security-hook call)
    (should (get-buffer "*gptel-permit-log*"))
    (with-current-buffer "*gptel-permit-log*"
      (let ((log-content (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Checking permissions for tool call `Read` with args:" log-content))
        (should (string-match-p "Evaluating rule for tool `Read`:" log-content))
        (should (string-match-p "Check: arg `:file_path` (value `/tmp/secret.txt`) against regexp `secret` -> SUCCESS" log-content))
        (should (string-match-p "Result: Rule matched perfectly. Action: `deny`" log-content))
        (should (string-match-p "Resulting Decision: REJECT (action: deny) -> auto-denied :block" log-content))))

    ;; Clean up
    (when (get-buffer "*gptel-permit-log*")
      (kill-buffer "*gptel-permit-log*"))))


(provide 'gptel-permit-test)
;;; gptel-permit-test.el ends here
