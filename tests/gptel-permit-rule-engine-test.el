;;; gptel-permit-rule-engine-test.el --- Tests for rule matching engine -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Tool-group targeting
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-tool-group-match ()
  "Rule targeting a tool-group matches any tool in that group."
  (let ((rule '(:tool-group read :conditions ((:file_path . "secret")) :action deny))
        (gptel-permit-rules (list '(:tool-group read :conditions ((:file_path . "secret")) :action deny))))
    ;; Read belongs to "read" group → matches
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "/tmp/secret.txt"))
                'deny))
    ;; Glob belongs to "read" group → matches
    (should (eq (gptel-permit--match-rule-p rule "Glob" '(:file_path "/tmp/secret.txt"))
                'deny))
    ;; Write does NOT belong to "read" group → no match
    (should (null (gptel-permit--match-rule-p rule "Write" '(:file_path "/tmp/secret.txt"))))))

(ert-deftest gptel-permit-rule-arg-group-match ()
  "Rule targeting an arg-group matches any qualifying arg on the tool."
  (let ((rule '(:tool-group write :conditions ((:arg-group path . "secret")) :action deny)))
    ;; Write has :filename in "path" arg-group → matches via :filename
    (should (eq (gptel-permit--match-rule-p rule "Write"
                                            '(:path "/tmp" :filename "secret.txt" :content "hello"))
                'deny))
    ;; Mkdir has :parent in "path" arg-group → matches
    (should (eq (gptel-permit--match-rule-p rule "Mkdir"
                                            '(:parent "/tmp/secret/" :name "subdir"))
                'deny))
    ;; Edit has :path in "path" arg-group but value doesn't match → no match
    (should (null (gptel-permit--match-rule-p rule "Edit"
                                              '(:path "/tmp/public.txt" :old_str "x" :new_str "y"))))))

(ert-deftest gptel-permit-rule-arg-group-any-match-semantics ()
  "For an arg-group condition, ANY matching argument satisfies the condition."
  (let ((rule '(:tool-group write :conditions ((:arg-group path . "secret")) :action deny)))
    ;; Write: :path doesn't match, :filename DOES → condition satisfied
    (should (eq (gptel-permit--match-rule-p rule "Write"
                                            '(:path "/safe" :filename "secret.log" :content ""))
                'deny))))

;; -------------------------------------------------------------------
;; Precedence: concrete over group
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-concrete-tool-overrides-tool-group ()
  "When both :tool and :tool-group are present, :tool wins."
  (let ((rule '(:tool "Read" :tool-group write :conditions ((:file_path . "data")) :action allow)))
    ;; Rule uses :tool "Read", ignores :tool-group write
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "data.txt")) 'allow))
    ;; Write would match :tool-group but :tool "Read" doesn't → no match
    (should (null (gptel-permit--match-rule-p rule "Write" '(:path "data.txt"))))))

(ert-deftest gptel-permit-rule-concrete-arg-overrides-arg-group ()
  "A concrete arg key in a condition is tested directly, not through arg-groups."
  (let ((rule '(:tool "Write" :conditions ((:filename . "safe")) :action allow)))
    ;; :filename is tested directly, not resolved through arg-group
    (should (eq (gptel-permit--match-rule-p rule "Write"
                                            '(:path "/tmp" :filename "safe_file.txt" :content ""))
                'allow))))

;; -------------------------------------------------------------------
;; No tool/tool-group: matches any tool
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-no-tool-restriction ()
  "A rule with no :tool or :tool-group matches any tool."
  (let ((rule '(:conditions ((:arg-group path . :inside-protected-dirs)) :action ask)))
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "/home/user/.ssh/config"))
                'ask))
    (should (eq (gptel-permit--match-rule-p rule "Write" '(:path "/home/user/.ssh/authorized_keys"
                                                               :filename "x" :content ""))
                'ask))
    (should (eq (gptel-permit--match-rule-p rule "Bash" '(:command "ls"))
                'ask))))

;; -------------------------------------------------------------------
;; Predicate conditions
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-predicate-inside-project ()
  "Predicate :inside-project resolves correctly."
  (let ((default-directory "/tmp/test-project/")
        (rule '(:tool-group read :conditions ((:arg-group path . :inside-project)) :action allow)))
    ;; File inside project
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "src/main.el")) 'allow))
    ;; File outside project (absolute path elsewhere)
    (should (null (gptel-permit--match-rule-p rule "Read" '(:file_path "/etc/hosts"))))))

(ert-deftest gptel-permit-rule-predicate-outside-project ()
  "Predicate :outside-project resolves correctly."
  (let ((default-directory "/tmp/test-project/")
        (rule '(:tool-group read :conditions ((:arg-group path . :outside-project)) :action ask)))
    ;; File outside project
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "/etc/hosts")) 'ask))
    ;; File inside project
    (should (null (gptel-permit--match-rule-p rule "Read" '(:file_path "src/main.el"))))))

(ert-deftest gptel-permit-rule-predicate-inside-protected-dirs ()
  "Predicate :inside-protected-dirs resolves correctly."
  (let ((default-directory "/home/user/")
        (gptel-permit-protected-dirs '("~/.ssh/" "~/.gnupg/"))
        (rule '(:conditions ((:arg-group path . :inside-protected-dirs)) :action ask)))
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "~/.ssh/config")) 'ask))
    (should (eq (gptel-permit--match-rule-p rule "Write" '(:path "~/.ssh/" :filename "x" :content ""))
                'ask))
    ;; Not a protected dir
    (should (null (gptel-permit--match-rule-p rule "Read" '(:file_path "~/Documents/notes.txt"))))))

(ert-deftest gptel-permit-rule-predicate-unknown-keyword ()
  "An unknown predicate keyword fails with a warning."
  (let ((rule '(:tool "Bash" :conditions ((:command . :nonexistent-pred)) :action allow)))
    (should (null (gptel-permit--match-rule-p rule "Bash" '(:command "ls"))))))

;; -------------------------------------------------------------------
;; First match wins
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-first-match-wins ()
  "Session-local rules are checked before global rules."
  (let ((gptel-permit-rules
         '((:tool "Read" :conditions ((:file_path . "logs")) :action allow)))
        (gptel-permit-global-rules
         '((:tool "Read" :conditions ((:file_path . "logs")) :action ask))))
    (should (eq (gptel-permit--rule-action "Read" '(:file_path "logs/debug.txt"))
                'allow))))

(ert-deftest gptel-permit-rule-no-match-fallback ()
  "When no rule matches, nil is returned."
  (let ((gptel-permit-rules nil)
        (gptel-permit-global-rules nil))
    (should (null (gptel-permit--rule-action "Read" '(:file_path "random.txt"))))))

;; -------------------------------------------------------------------
;; Path normalization in rules
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-path-normalization ()
  "Path args are expanded before regexp matching when targeting path arg-group."
  (let ((default-directory "/home/user/")
        (rule '(:tool-group read :conditions ((:arg-group path . "^/home/user/docs/")) :action allow)))
    ;; Relative path expanded
    (should (eq (gptel-permit--match-rule-p rule "Read" '(:file_path "docs/readme.txt"))
                'allow))
    ;; Absolute path outside docs
    (should (null (gptel-permit--match-rule-p rule "Read" '(:file_path "/home/user/src/main.el"))))))

(ert-deftest gptel-permit-rule-nil-path-no-match ()
  "A nil path argument causes the condition to fail."
  (let ((rule '(:tool "Glob" :conditions ((:arg-group path . ".*")) :action allow)))
    (should (null (gptel-permit--match-rule-p rule "Glob" '(:pattern "*.el" :path nil))))))

;; -------------------------------------------------------------------
;; Path traversal as default rule
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-path-traversal-detected ()
  "Default rule catches '..' in a path argument."
  (let ((rule '(:tool-group write :conditions ((:arg-group path . "^\\\\.\\\\.|^/")) :action ask)))
    (should (eq (gptel-permit--match-rule-p rule "Write"
                                            '(:path "/tmp" :filename "../etc/passwd" :content "x"))
                'ask))
    (should (eq (gptel-permit--match-rule-p rule "Mkdir"
                                            '(:parent "/tmp" :name "/etc/secret"))
                'ask))))

(ert-deftest gptel-permit-rule-path-traversal-normal-path-passes ()
  "Normal relative paths do not trigger traversal rule."
  (let ((rule '(:tool-group write :conditions ((:arg-group path . "^\\\\.\\\\.|^/")) :action ask)))
    (should (null (gptel-permit--match-rule-p rule "Write"
                                              '(:path "/tmp" :filename "safe.txt" :content "x"))))
    (should (null (gptel-permit--match-rule-p rule "Mkdir"
                                              '(:parent "/tmp" :name "subdir"))))))

(provide 'gptel-permit-rule-engine-test)
;;; gptel-permit-rule-engine-test.el ends here
