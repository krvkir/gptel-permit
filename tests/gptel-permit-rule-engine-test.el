;;; gptel-permit-rule-engine-test.el --- Tests for rule matching engine -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Tool-group targeting
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-tool-group-match ()
  "Rule targeting a tool-group matches any tool in that group."
  (let ((rule '(:tool-group read :conditions ((:file_path . "secret")) :action deny)))
    ;; Read belongs to "read" group → matches
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/tmp/secret.txt"))))
                'deny))
    ;; Glob belongs to "read" group → matches
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Glob" :args '(:file_path "/tmp/secret.txt"))))
                'deny))
    ;; Write does NOT belong to "read" group → no match
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Write" :args '(:file_path "/tmp/secret.txt"))))))))

(ert-deftest gptel-permit-rule-arg-group-match ()
  "Rule targeting an arg-group matches any qualifying arg on the tool."
  (let ((rule '(:tool-group write :conditions ((path . "secret")) :action deny)))
    ;; Write has :filename in "path" arg-group → matches via :filename
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "/tmp" :filename "secret.txt" :content "hello"))))
                'deny))
    ;; Mkdir has :parent in "path" arg-group → matches
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Mkdir" :args '(:parent "/tmp/secret/" :name "subdir"))))
                'deny))
    ;; Edit has :path in "path" arg-group but value doesn't match → no match
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Edit" :args '(:path "/tmp/public.txt" :old_str "x" :new_str "y"))))))))

(ert-deftest gptel-permit-rule-arg-group-any-match-semantics ()
  "For an arg-group condition, ANY matching argument satisfies the condition."
  (let ((rule '(:tool-group write :conditions ((path . "secret")) :action deny)))
    ;; Write: :path doesn't match, :filename DOES → condition satisfied
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "/safe" :filename "secret.log" :content ""))))
                'deny))))

;; -------------------------------------------------------------------
;; Precedence: concrete over group
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-concrete-tool-overrides-tool-group ()
  "When both :tool and :tool-group are present, :tool wins."
  (let ((rule '(:tool "Read" :tool-group write :conditions ((:file_path . "data")) :action allow)))
    ;; Rule uses :tool "Read", ignores :tool-group write
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "data.txt")))) 'allow))
    ;; Write would match :tool-group but :tool "Read" doesn't → no match
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "data.txt"))))))))

(ert-deftest gptel-permit-rule-concrete-arg-overrides-arg-group ()
  "A concrete arg key in a condition is tested directly, not through arg-groups."
  (let ((rule '(:tool "Write" :conditions ((:filename . "safe")) :action allow)))
    ;; :filename is tested directly, not resolved through arg-group
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "/tmp" :filename "safe_file.txt" :content ""))))
                'allow))))

;; -------------------------------------------------------------------
;; No tool/tool-group: matches any tool with matching args
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-no-tool-restriction ()
  "A rule with no :tool or :tool-group matches any tool with matching args."
  (let ((gptel-permit-protected-dirs '("~/.ssh/" "~/.gnupg/"))
        (default-directory "/home/user/")
        (rule '(:conditions ((path . :inside-protected-dirs)) :action ask)))
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "~/.ssh/config"))))
                'ask))
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "~/.ssh/authorized_keys"
                                                               :filename "x" :content ""))))
                'ask))
    ;; Bash has no path-group args, so the condition fails → no match
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "ls"))))))))

;; -------------------------------------------------------------------
;; Predicate conditions
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-predicate-inside-project ()
  "Predicate :inside-project resolves correctly."
  (let ((buffer-file-name (expand-file-name "dummy.el" temporary-file-directory))
        (rule '(:tool-group read :conditions ((path . :inside-project)) :action allow)))
    ;; File inside project
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "src/main.el")))) 'allow))
    ;; File outside project (absolute path elsewhere)
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/etc/hosts"))))))))

(ert-deftest gptel-permit-rule-predicate-outside-project ()
  "Predicate :outside-project resolves correctly."
  (let ((buffer-file-name (expand-file-name "dummy.el" temporary-file-directory))
        (rule '(:tool-group read :conditions ((path . :outside-project)) :action ask)))
    ;; File outside project
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/etc/hosts")))) 'ask))
    ;; File inside project
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "src/main.el"))))))))

(ert-deftest gptel-permit-rule-predicate-inside-protected-dirs ()
  "Predicate :inside-protected-dirs resolves correctly."
  (let ((default-directory "/home/user/")
        (gptel-permit-protected-dirs '("~/.ssh/" "~/.gnupg/"))
        (rule '(:conditions ((path . :inside-protected-dirs)) :action ask)))
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "~/.ssh/config")))) 'ask))
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "~/.ssh/" :filename "x" :content ""))))
                'ask))
    ;; Not a protected dir
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "~/Documents/notes.txt"))))))))

(ert-deftest gptel-permit-rule-predicate-unknown-keyword ()
  "An unknown predicate keyword fails with a warning."
  (let ((rule '(:tool "Bash" :conditions ((:command . :nonexistent-pred)) :action allow)))
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Bash" :args '(:command "ls"))))))))

;; -------------------------------------------------------------------
;; Rule scopes: registry order, cross-scope precedence
;; -------------------------------------------------------------------

(defun gptel-permit-rule-engine-test--registry (session notebook project global)
  "Registry like `gptel-permit-rule-scopes' with canned readers.
Each of SESSION, NOTEBOOK, PROJECT and GLOBAL is the rule list the
corresponding reader returns (or nil)."
  `((session  :reader ,(lambda () session)
              :writer gptel-permit--write-session-rule)
    (notebook :reader ,(lambda () notebook)
              :writer gptel-permit--write-notebook-rule)
    (project  :reader ,(lambda () project)
              :writer gptel-permit--write-project-rule)
    (global   :reader ,(lambda () global)
              :writer gptel-permit--write-global-rule)))

(defun gptel-permit-rule-engine-test--clear-log ()
  "Erase the `*gptel-permit-log*' buffer."
  (with-current-buffer (get-buffer-create "*gptel-permit-log*")
    (erase-buffer)))

(defun gptel-permit-rule-engine-test--log ()
  "Return the current contents of the `*gptel-permit-log*' buffer."
  (with-current-buffer (get-buffer-create "*gptel-permit-log*")
    (buffer-string)))

(ert-deftest gptel-permit-scope-registry-order ()
  "The scope registry lists session, notebook, project, global, in order,
each entry carrying both a reader and a writer."
  (should (equal (mapcar #'car gptel-permit-rule-scopes)
                 '(session notebook project global)))
  (should (cl-every (lambda (spec)
                      (and (plist-get spec :reader)
                           (plist-get spec :writer)))
                    (mapcar #'cdr gptel-permit-rule-scopes))))

(ert-deftest gptel-permit-rule-first-match-wins ()
  "Session-local rules are checked before global rules; the return
names the matching rule and its scope (RULE . SCOPE)."
  (let ((gptel-permit-rules
         '((:tool "Read" :conditions ((:file_path . "logs")) :action allow)))
        (gptel-permit-global-rules
         '((:tool "Read" :conditions ((:file_path . "logs")) :action ask)))
        (gptel-permit-notebook-rules nil))
    (let* ((result (gptel-permit--find-action
                    "test-id"
                    (gptel-permit--enrich-tool-call
                     (list :name "Read" :args '(:file_path "logs/debug.txt"))))))
      (should (eq (cdr result) 'session))
      (should (eq (plist-get (car result) :action) 'allow))
      ;; The collection stays in registry order with no persisted stores:
      ;; one session rule, one global rule.
      (should (equal (mapcar #'cdr (gptel-permit--scoped-rules))
                     '(session global))))))

(ert-deftest gptel-permit-rule-no-match-fallback ()
  "When no rule matches, nil is returned."
  (let ((gptel-permit-rules nil)
        (gptel-permit-global-rules nil))
    (should (null (gptel-permit--find-action
                   "test-id"
                   (gptel-permit--enrich-tool-call
                    (list :name "Read" :args '(:file_path "random.txt"))))))))

(ert-deftest gptel-permit-engine-scope-order-decides ()
  "One matching rule per scope with different actions: the narrowest
scope wins and the reported scope is that scope."
  (with-temp-buffer
    (let* ((scopes-seen nil)
           (gptel-permit-events-functions
            (list (lambda (_id tc type _pl)
                    (when (eq type :rule-match)
                      (push (plist-get tc :rule-scope) scopes-seen)))))
           (gptel-permit-rule-scopes
            (gptel-permit-rule-engine-test--registry
             '((:tool "Bash" :action ask))
             '((:tool "Bash" :action allow))
             '((:tool "Bash" :action deny))
             '((:tool "Bash" :action allow)))))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t)))
      (should (equal scopes-seen '(session))))))

(ert-deftest gptel-permit-engine-notebook-overrides-project-and-global ()
  "A notebook rule outranks matching project and global rules."
  (let* ((scopes-seen nil)
         (gptel-permit-events-functions
          (list (lambda (_id tc type _pl)
                  (when (eq type :rule-match)
                    (push (plist-get tc :rule-scope) scopes-seen)))))
         (gptel-permit-rules nil)
         (gptel-permit-global-rules '((:tool "Bash" :action ask)))
         (gptel-permit-rule-scopes
          (gptel-permit-rule-engine-test--registry
           nil
           '((:tool "Bash" :action allow))
           '((:tool "Bash" :action ask))
           gptel-permit-global-rules)))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm nil)))
    (should (equal scopes-seen '(notebook)))))

(ert-deftest gptel-permit-engine-project-overrides-global ()
  "A project rule (by tool-group) outranks a matching global allow."
  (let* ((scopes-seen nil)
         (gptel-permit-events-functions
          (list (lambda (_id tc type _pl)
                  (when (eq type :rule-match)
                    (push (plist-get tc :rule-scope) scopes-seen)))))
         (gptel-permit-rules nil)
         (gptel-permit-global-rules
          '((:tool-group read :action allow)))
         (gptel-permit-rule-scopes
          (gptel-permit-rule-engine-test--registry
           nil nil
           '((:tool-group read :action deny))
           gptel-permit-global-rules)))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Read" :args '(:file_path "x.txt")))
                   '(:block "auto-denied")))
    (should (equal scopes-seen '(project)))))

(ert-deftest gptel-permit-engine-defer-only-after-every-scope-exhausted ()
  "Every scope offers its rules before a later, matching one decides."
  (let ((gptel-permit-rules
         '((:tool "Bash" :conditions ((:command . "^no-match")) :action ask)))
        (gptel-permit-global-rules
         '((:tool "Bash" :conditions ((:command . "^run")) :action ask)))
        (gptel-permit-rule-scopes
         (gptel-permit-rule-engine-test--registry
          '((:tool "Bash" :conditions ((:command . "^no-match")) :action ask))
          '((:tool "Bash" :conditions ((:command . "^no-match")) :action ask))
          '((:tool "Bash" :conditions ((:command . "^no-match")) :action ask))
          '((:tool "Bash" :conditions ((:command . "^run")) :action ask)))))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "run ls")))
                   '(:confirm t)))))

(ert-deftest gptel-permit-engine-no-persisted-rules-unchanged ()
  "With no notebook property and no project store, the engine's verdicts
are the session+global behavior that predates scopes."
  (with-temp-buffer
    (let ((gptel-permit-rules
           '((:tool "Bash" :conditions ((:command . "^make")) :action allow)))
          (gptel-permit-global-rules
           '((:tool "Read" :conditions ((:file_path . ".*")) :action allow)
             (:action ask)))
          (gptel-permit-notebook-rules nil))
      ;; The notebook and project readers find no storage in this buffer.
      (should (null (gptel-permit--read-notebook-rules)))
      (should (null (gptel-permit--read-project-rules)))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "make test")))
                     '(:confirm nil)))
      ;; No tool-specific rule matches "other"; the universal global
      ;; fallback (:action ask) decides — exactly as it did pre-change.
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "other")))
                     '(:confirm t)))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Read" :args '(:file_path "whatever")))
                     '(:confirm nil))))))

(ert-deftest gptel-permit-engine-scope-removal-disables-scope ()
  "Removing a scope's entry from the registry disables the scope
entirely: its store is not even read and its rules cannot decide."
  (let* ((project-reads 0)
         (gptel-permit-rules nil)
         (gptel-permit-global-rules nil)
         (counting-project
          `((project :reader ,(lambda ()
                                (cl-incf project-reads)
                                '((:tool "Bash" :action allow)))
                     :writer gptel-permit--write-project-rule)))
         (no-project
          (cl-remove-if (pcase-lambda (`(,scope . ,_))
                          (eq scope 'project))
                        (copy-sequence gptel-permit-rule-scopes))))
    ;; With the entry present the counting reader is consulted and its
    ;; allow rule decides:
    (let ((gptel-permit-rule-scopes counting-project))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm nil)))
      (should (= project-reads 1)))
    ;; With the entry removed the reader is never called and the same
    ;; call defers:
    (let ((gptel-permit-rule-scopes no-project))
      (should (null (gptel-permit--apply-rules
                     (list :name "Bash" :args '(:command "ls")))))
      (should (= project-reads 1)))))

(ert-deftest gptel-permit-engine-empty-scope-contributes-nothing ()
  "Scopes without storage behave as if removed: matching proceeds over
the remaining rules exactly the same."
  (with-temp-buffer
    (let ((gptel-permit-rules
           '((:tool "Bash" :action ask)))
          (gptel-permit-global-rules nil))
      ;; Every canned reader returns nil: the empty scopes vanish and
      ;; only the session rule is collected.
      (should (equal (mapcar #'cdr (gptel-permit--scoped-rules))
                     '(session)))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm t))))))

(ert-deftest gptel-permit-log-names-matched-scope-and-source ()
  "With logging on, the log names the matched scope and where its rule
came from — the store file for a project rule."
  (let ((gptel-permit-log-enabled t)
        (gptel-permit-rules nil)
        (gptel-permit-global-rules nil))
    (gptel-permit-rule-engine-test--clear-log)
    (with-temp-buffer
      (should (equal (gptel-permit--scoped-rules)
                     (gptel-permit--scoped-rules)))
      (let ((gptel-permit-rule-scopes
             (gptel-permit-rule-engine-test--registry
              nil
              nil
              '((:tool "Bash"
                       :conditions ((:command . "^make"))
                       :action allow
                       :origin (:scope project :file "/proj/gui/.gptel-permit-rules")))
              nil)))
        (should (equal (gptel-permit--apply-rules
                        (list :name "Bash" :args '(:command "make test")))
                       '(:confirm nil))))
      (let ((log (gptel-permit-rule-engine-test--log)))
        (should (string-match-p "scope=project file=/proj/gui/.gptel-permit-rules" log))
        (should (string-match-p "action=allow" log))))))

(ert-deftest gptel-permit-log-names-notebook-heading-source ()
  "A notebook match names its heading in the log."
  (let ((gptel-permit-log-enabled t)
        (gptel-permit-rules nil)
        (gptel-permit-global-rules nil))
    (gptel-permit-rule-engine-test--clear-log)
    (with-temp-buffer
      (let ((gptel-permit-rule-scopes
             (gptel-permit-rule-engine-test--registry
              nil
              '((:tool "Bash"
                       :conditions ((:command . "^make"))
                       :action allow
                       :origin (:scope notebook :file "/n/notes.org" :heading "Work setup")))
              nil
              nil)))
        (gptel-permit--apply-rules (list :name "Bash" :args '(:command "make test"))))
      (should (string-match-p "scope=notebook.*heading=Work setup"
                              (gptel-permit-rule-engine-test--log))))))

(ert-deftest gptel-permit-log-no-match-names-no-scope ()
  "When no rule matches, the log records the absence of a match without
naming a contributing scope."
  (let ((gptel-permit-log-enabled t))
    (gptel-permit-rule-engine-test--clear-log)
    (with-temp-buffer
      (let ((gptel-permit-rules nil)
            (gptel-permit-global-rules nil))
        (should (null (gptel-permit--apply-rules
                       (list :name "Read" :args '(:file_path "x.txt"))))))
      (let ((log (gptel-permit-rule-engine-test--log)))
        (should (string-match-p "Verdict: none (fallback)" log))
        (should-not (string-match-p "scope=" log))))))

;; -------------------------------------------------------------------
;; Path normalization in rules
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-path-normalization ()
  "Path args are expanded before regexp matching when targeting path arg-group."
  (let ((default-directory "/home/user/")
        (rule '(:tool-group read :conditions ((path . "^/home/user/docs/")) :action allow)))
    ;; Relative path expanded
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "docs/readme.txt"))))
                'allow))
    ;; Absolute path outside docs
    (should (null (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Read" :args '(:file_path "/home/user/src/main.el"))))))))

(ert-deftest gptel-permit-rule-nil-path-treated-as-empty-string ()
  "A nil path argument is treated as an empty string, resolving to current directory."
  (let ((rule '(:tool "Glob" :conditions ((path . ".*")) :action allow))
        (default-directory "/home/user/"))
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Glob" :args '(:pattern "*.el" :path nil))))
                'allow))))

(ert-deftest gptel-permit-rule-missing-path-treated-as-empty-string ()
  "A missing path argument is treated as an empty string, resolving to current directory."
  (let ((rule '(:tool "Glob" :conditions ((path . ".*")) :action allow))
        (default-directory "/home/user/"))
    (should (eq (gptel-permit--match-rule-p rule (gptel-permit--enrich-tool-call (list :name "Glob" :args '(:pattern "*.el"))))
                'allow))))


;; -------------------------------------------------------------------
;; Path traversal as default rule
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-rule-path-traversal-detected ()
  "Path traversal predicate catches '..' and leading '/' in filename/name args."
  (let ((rule-filename '(:tool "Write" :conditions ((:filename . :path-traversal)) :action ask))
        (rule-name '(:tool "Mkdir" :conditions ((:name . :path-traversal)) :action ask)))
    (should (eq (gptel-permit--match-rule-p rule-filename (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "/tmp" :filename "/etc/passwd" :content "x"))))
                'ask))
    (should (eq (gptel-permit--match-rule-p rule-name (gptel-permit--enrich-tool-call (list :name "Mkdir" :args '(:parent "/tmp" :name "../secret"))))
                'ask))))

(ert-deftest gptel-permit-rule-path-traversal-normal-path-passes ()
  "Normal filenames do not trigger traversal predicate."
  (let ((rule-trav '(:tool-group write :conditions ((:filename . :path-traversal)) :action ask)))
    (should (null (gptel-permit--match-rule-p rule-trav (gptel-permit--enrich-tool-call (list :name "Write" :args '(:path "/tmp" :filename "safe.txt" :content "x"))))))
    (should (null (gptel-permit--match-rule-p rule-trav (gptel-permit--enrich-tool-call (list :name "Mkdir" :args '(:parent "/tmp" :name "subdir"))))))))

(provide 'gptel-permit-rule-engine-test)
;;; gptel-permit-rule-engine-test.el ends here
