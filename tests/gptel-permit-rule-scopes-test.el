;;; gptel-permit-rule-scopes-test.el --- Tests for rule scopes -*- lexical-binding: t; -*-

;; Tests for the rule scopes: the registry, the notebook scope (the Org
;; GPTEL_PERMIT_RULES property and the markdown file-local variable),
;; the project scope (`.gptel-permit-rules' stores on the directory
;; chain) and the persisted-rule validation ("data, not code").

(require 'ert)
(require 'gptel)
(require 'gptel-permit)

;; -------------------------------------------------------------------
;; Helpers
;; -------------------------------------------------------------------

(defmacro gptel-permit-rule-scopes-test--with-notebook (kind &rest body)
  "Run BODY in a notebook buffer visiting a fresh temp file.
KIND is `org' (an `org-mode' buffer) or anything else (a `text-mode'
buffer; that is the non-Org notebook branch).  The buffer visits a
fresh file, so `buffer-file-name' is real and no store can be picked
up outside `temporary-file-directory'."
  (declare (indent 1))
  (let ((file (make-symbol "file"))
        (buf  (make-symbol "buf"))
        (modefn (if (eq kind 'org) 'org-mode 'text-mode)))
    `(let ((,file (make-temp-file "gptel-permit-notebook-"
                                  nil ,(if (eq kind 'org) ".org" ".md"))))
       (unwind-protect
           (let ((,buf (find-file-noselect ,file)))
             (with-current-buffer ,buf
               (,modefn)
               ,@body))
         (let ((,buf (get-file-buffer ,file)))
           (when (and (bufferp ,buf) (buffer-live-p ,buf))
             (with-current-buffer ,buf
               (set-buffer-modified-p nil))
             (kill-buffer ,buf))
           (when (file-exists-p ,file) (delete-file ,file)))))))

(defmacro gptel-permit-rule-scopes-test--with-org (text &rest body)
  "Run BODY in an `org-mode' temp buffer containing TEXT."
  (declare (indent 1))
  (let ((buf (make-symbol "org-buf")))
    `(let ((,buf (generate-new-buffer " *scopes-org*")))
       (unwind-protect
           (with-current-buffer ,buf
             (insert ,text)
             (org-mode)
             (goto-char (point-min))
             ,@body)
         (with-current-buffer ,buf
           (set-buffer-modified-p nil))
         (kill-buffer ,buf)))))

(defun gptel-permit-rule-scopes-test--org-with-file-drawer (value &optional drawer-first)
  "Org notebook text with a file-level drawer property VALUE.
When DRAWER-FIRST is non-nil the drawer precedes any keyword line."
  (if drawer-first
      (format ":PROPERTIES:\n:GPTEL_PERMIT_RULES: %s\n:END:\n#+TITLE: A notebook\n\n* First heading\nbody\n" value)
    (format "#+TITLE: A notebook\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: %s\n:END:\n\n* First heading\nbody\n" value)))

(defun gptel-permit-rule-scopes-test--make-project ()
  "Create a fresh temp project root; return its directory path."
  (make-temp-file "gptel-permit-proj-" t))

(defun gptel-permit-rule-scopes-test--write-store (dir contents)
  "Write a `.gptel-permit-rules' store with CONTENTS into DIR; return FILE."
  (let ((file (expand-file-name gptel-permit-store-file-name dir)))
    (write-region contents nil file nil 'silent)
    file))

(defmacro gptel-permit-rule-scopes-test--with-project (root &rest body)
  "Run BODY in a temp buffer inside the project ROOT.
ROOT is an expression evaluating to the project's root directory.
`project-current' is stubbed to a transient project rooted there, so
`gptel-permit--project-root' resolves to ROOT; the parse cache starts
empty."
  (declare (indent 1))
  (let ((r (make-symbol "proj-root")))
    `(let ((,r ,root)
           (gptel-permit--project-rules-cache nil))
       (with-temp-buffer
         (setq default-directory (file-name-as-directory ,r))
         (cl-letf (((symbol-function 'project-current)
                    (lambda (&optional _maybe-prompt _dir)
                      (cons 'transient (directory-file-name ,r)))))
           ,@body)))))

;; -------------------------------------------------------------------
;; Registry, origins, validation primitives
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-scopes-registry-shape ()
  "The scope registry lists the four scopes in match order, each with
a reader and a writer."
  (should (equal (mapcar #'car gptel-permit-rule-scopes)
                 '(session notebook project global)))
  (should (cl-every (lambda (spec)
                      (and (functionp (plist-get spec :reader))
                           (functionp (plist-get spec :writer))))
                    (mapcar #'cdr gptel-permit-rule-scopes))))

(ert-deftest gptel-permit-valid-persisted-rule-table ()
  "The persisted-rule shape accepts data and rejects code-shaped forms."
  (should (gptel-permit--valid-persisted-rule-p
           '(:tool "Bash" :conditions ((:command . "^make")) :action allow)))
  (should (gptel-permit--valid-persisted-rule-p
           '(:conditions ((path . :inside-project)) :action ask)))
  (should (gptel-permit--valid-persisted-rule-p
           '(:tool "Bash" :conditions ((:command . gptel-permit-judge-safe-p))
                  :action ask)))
  (should (gptel-permit--valid-persisted-rule-p '(:tool-group search :action allow)))
  (should-not (gptel-permit--valid-persisted-rule-p
               '(:tool "Bash"
                       :conditions ((:command . (lambda (v tc) t)))
                       :action allow)))
  (should-not (gptel-permit--valid-persisted-rule-p '(:conditions "x" :action allow)))
  (should-not (gptel-permit--valid-persisted-rule-p "not a rule"))
  (should-not (gptel-permit--valid-persisted-rule-p '((:tool "Read" :action allow))))
  (should-not (gptel-permit--valid-persisted-rule-p nil))
  ;; A symbol naming no function is rejected as a condition value.
  (should-not (gptel-permit--valid-persisted-rule-p
               '(:tool "Bash" :conditions ((:command . no-such-function-here))
                      :action allow))))

(ert-deftest gptel-permit-origin-strip-and-attest ()
  "Origins are overwritten by the reader's attestation and stripped
before any write; a stripped rule loses the key entirely."
  (let* ((rule '(:tool "Bash" :action allow
                       :origin (:scope global :file "/forged")))
         (attested (gptel-permit--rule-with-origin
                    rule '(:scope project :file "/p"))))
    ;; Attestation overwrites a store-supplied origin:
    (should (equal (plist-get attested :origin) '(:scope project :file "/p")))
    (should (equal (plist-get attested :tool) "Bash"))
    ;; exactly one origin key:
    (should (= (cl-count :origin attested :test #'eq) 1))
    ;; stripping removes the key entirely:
    (should-not (plist-member (gptel-permit--strip-origin rule) :origin))
    ;; a rule without an origin passes through unmodified:
    (should (equal (gptel-permit--strip-origin '(:tool "Bash" :action allow))
                   '(:tool "Bash" :action allow)))))

(ert-deftest gptel-permit-format-origin ()
  "The log format names the scope and, where meaningful, the source."
  (should (equal (gptel-permit--format-origin
                  '(:scope project :file "/p/.gptel-permit-rules"))
                 "scope=project file=/p/.gptel-permit-rules"))
  (should (equal (gptel-permit--format-origin
                  '(:scope notebook :file "/n.org" :heading "Setup"))
                 "scope=notebook file=/n.org heading=Setup"))
  (should (equal (gptel-permit--format-origin '(:scope session))
                 "scope=session"))
  (should (null (gptel-permit--format-origin nil))))

(ert-deftest gptel-permit-scoped-rules-origins-attested ()
  "The collector attaches a bare scope origin to un-attested session
and global rules and keeps reader-attested rules' richer origins."
  (with-temp-buffer
    (let ((gptel-permit-rules '((:tool "Bash" :action ask)))
          (gptel-permit-global-rules '((:tool "Read" :action ask)))
          (gptel-permit-rule-scopes
           `((session :reader gptel-permit--read-session-rules
                      :writer gptel-permit--write-session-rule)
             (notebook :reader ,(lambda () '((:tool "Bash" :action allow :origin (:scope notebook :file "/n.md"))))
                       :writer gptel-permit--write-notebook-rule)
             (project :reader ,(lambda () nil) :writer gptel-permit--write-project-rule)
             (global :reader gptel-permit--read-global-rules
                     :writer gptel-permit--write-global-rule))))
      (let ((scoped (gptel-permit--scoped-rules)))
        (should (equal (mapcar #'cdr scoped) '(session notebook global)))
        (let* ((session-origin (plist-get (car (car scoped)) :origin))
               (global-origin (plist-get (car (nth 2 scoped)) :origin))
               (nb-origin (plist-get (car (nth 1 scoped)) :origin)))
          (should (equal session-origin '(:scope session)))
          (should (equal global-origin '(:scope global)))
          (should (equal nb-origin '(:scope notebook :file "/n.md"))))
        ;; The user's own rule plists were not mutated with :origin keys.
        (should (equal gptel-permit-rules '((:tool "Bash" :action ask))))
        (should (equal gptel-permit-global-rules '((:tool "Read" :action ask))))))))

;; -------------------------------------------------------------------
;; Session and global scope storage
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-session-reader-writer-trivial ()
  "The session reader is the buffer-local rules; the writer pushes an
origin-stripped rule onto it."
  (with-temp-buffer
    (let ((gptel-permit-rules '((:tool "Bash" :action allow)))
          (gptel-permit-global-rules nil))
      (should (equal (gptel-permit--read-session-rules)
                     '((:tool "Bash" :action allow))))
      (gptel-permit--write-session-rule
       '(:tool "Read" :action ask :origin (:scope notebook :file "/x")))
      ;; push prepends; the origin was stripped:
      (should (equal gptel-permit-rules
                     '((:tool "Read" :action ask) (:tool "Bash" :action allow)))))))

(ert-deftest gptel-permit-global-writer-updates-running-value ()
  "The global writer prepends the rule to the running value and saves
the option through the Customize machinery to the custom file."
  (let* ((tmp-custom (make-temp-file "gptel-permit-custom-" nil ".el")))
    (unwind-protect
        (let ((custom-file tmp-custom)
              (user-init-file tmp-custom)
              (gptel-permit-global-rules '((:tool "Read" :action ask))))
          (gptel-permit--write-global-rule
           '(:tool "Bash" :action ask :origin (:scope session :file "/x")))
          ;; The running value gained the origin-stripped rule, prepended.
          (should (equal gptel-permit-global-rules
                         '((:tool "Bash" :action ask) (:tool "Read" :action ask))))
          ;; It was saved through Custom:
          (should (file-exists-p tmp-custom))
          (with-temp-buffer
            (insert-file-contents tmp-custom)
            (should (string-match-p "gptel-permit-global-rules" (buffer-string)))
            (should-not (string-match-p ":origin" (buffer-string)))))
      (when (file-exists-p tmp-custom) (delete-file tmp-custom)))))

;; -------------------------------------------------------------------
;; Notebook scope: Org storage (reading)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-notebook-org-file-level-governs ()
  "A file-level property governs the whole notebook."
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer
       "(:tool \"Bash\" :conditions ((:command . \"^make\")) :action allow)")
    (goto-char (point-max))
    (let ((rules (gptel-permit--read-notebook-rules)))
      (should (= (length rules) 1))
      (should (equal (plist-get (car rules) :action) 'allow))
      (should (equal (plist-get (car rules) :tool) "Bash")))))

(ert-deftest gptel-permit-notebook-org-non-matching-rule-falls-through ()
  "A non-matching notebook rule leaves the call to the later scopes."
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer
       "(:tool \"Bash\" :conditions ((:command . \"^make\")) :action allow)")
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules '((:tool-group read :action allow)))
          (gptel-permit-notebook-rules nil))
      (goto-char (point-max))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Read" :args '(:file_path "x.txt")))
                     '(:confirm nil)))
      ;; The read-allow does not match a Bash call that never matches the
      ;; notebook rule either; the engine defers (no universal fallback).
      (should (null (gptel-permit--apply-rules
                     (list :name "Bash" :args '(:command "sleep"))))))))

(ert-deftest gptel-permit-notebook-org-drawer-after-title-found ()
  "A drawer following `#+TITLE:' is still found at file level."
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer "(:action ask)")
    (should (equal (gptel-permit--notebook-org-file-level-value) "(:action ask)"))
    (should (integerp (gptel-permit--notebook-org-file-level-line)))))

(ert-deftest gptel-permit-notebook-org-drawer-first-found ()
  "A drawer placed before any keyword line is found too."
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer "(:action ask)" t)
    (should (equal (gptel-permit--notebook-org-file-level-value)
                   "(:action ask)"))))

(ert-deftest gptel-permit-notebook-org-file-level-line-nil-without-one ()
  "No file-level line: the position lookup returns nil."
  (gptel-permit-rule-scopes-test--with-org
      "* Heading\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:action ask)\n:END:\nbody\n"
    (should (null (gptel-permit--notebook-org-file-level-line)))))

(ert-deftest gptel-permit-notebook-org-heading-wins-in-subtree ()
  "A heading's own property governs point inside its subtree."
  (gptel-permit-rule-scopes-test--with-org
      (concat
       (gptel-permit-rule-scopes-test--org-with-file-drawer
        "(:tool \"Bash\" :action ask)")
       "** Setup\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:tool \"Bash\" :action deny)\n:END:\nsetup body\n")
    (goto-char (point-max))
    (should (equal (plist-get (car (gptel-permit--read-notebook-rules)) :action)
                   'deny))))

(ert-deftest gptel-permit-notebook-org-file-level-decides-elsewhere ()
  "Under a different position (file level) the file value decides."
  (gptel-permit-rule-scopes-test--with-org
      (concat
       (gptel-permit-rule-scopes-test--org-with-file-drawer
        "(:tool \"Bash\" :action ask)")
       "** Setup\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:tool \"Bash\" :action deny)\n:END:\nsetup body\n")
    (goto-char (point-min))
    (should (equal (plist-get (car (gptel-permit--read-notebook-rules)) :action)
                   'ask))))

(ert-deftest gptel-permit-notebook-org-nearest-ancestor-wins ()
  "A nested heading inherits the nearest ancestor's value, not the
file-level one."
  (gptel-permit-rule-scopes-test--with-org
      (concat
       (gptel-permit-rule-scopes-test--org-with-file-drawer
        "(:tool \"Bash\" :action ask)")
       "** Parent sets own\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:tool \"Bash\" :action deny)\n:END:\n*** Child sets none\nchild body\n")
    (goto-char (point-max))
    (should (equal (plist-get (car (gptel-permit--read-notebook-rules)) :action)
                   'deny))))

(ert-deftest gptel-permit-notebook-org-absent-returns-nil ()
  "No property anywhere: the notebook reader returns nil."
  (gptel-permit-rule-scopes-test--with-org
      "#+TITLE: A notebook\n\n* Only a heading\nbody\n"
    (should (null (gptel-permit--read-notebook-rules)))))

(ert-deftest gptel-permit-notebook-org-under-narrowing ()
  "Narrowing does not hide the notebook rules."
  (gptel-permit-rule-scopes-test--with-org
      (concat
       (gptel-permit-rule-scopes-test--org-with-file-drawer
        "(:tool \"Bash\" :action ask)")
       "** Narrowed subtree\ntarget body\n")
    ;; Narrow away everything from the first body line onward, so only
    ;; the subtree can be seen by the naive lookup:
    (narrow-to-region (save-excursion
                        (goto-char (point-min))
                        (forward-line 7)
                        (point))
                      (point-max))
    (goto-char (point-max))
    (let ((rules (gptel-permit--read-notebook-rules)))
      (should (= (length rules) 1))
      (should (equal (plist-get (car rules) :action) 'ask)))))

(ert-deftest gptel-permit-notebook-org-unreadable-property-signals ()
  "An unbalanced property value signals instead of returning nil,
letting the engine fail the call closed."
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer "(:tool \"Bash")
    (should-error (gptel-permit--read-notebook-rules))))

(ert-deftest gptel-permit-notebook-org-origin-heading-vs-file-level ()
  "A heading's rules carry an origin naming that heading; a file-level
read carries a file-level origin."
  (gptel-permit-rule-scopes-test--with-org
      (concat
       (gptel-permit-rule-scopes-test--org-with-file-drawer
        "(:tool \"Bash\" :action ask)")
       "** Work heading\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:tool \"Bash\" :action deny)\n:END:\nbody\n")
    (let ((bfn (buffer-file-name)))
      (goto-char (point-min))
      (let* ((rules (gptel-permit--read-notebook-rules))
             (origin (plist-get (car rules) :origin)))
        (should (equal origin
                       (list :scope 'notebook :file bfn :heading "file level"))))
      (goto-char (point-max))
      (let* ((rules (gptel-permit--read-notebook-rules))
             (origin (plist-get (car rules) :origin)))
        (should (equal (plist-get origin :scope) 'notebook))
        (should (equal (plist-get origin :file) bfn))
        (should (equal (plist-get origin :heading) "Work heading"))))))

(ert-deftest gptel-permit-notebook-org-origin-overwrites-forged ()
  "A hand-forged `:origin' in the stored value is overwritten by the
reader's own origin, and matching is unaffected by the origin field."
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer
       "(:tool \"Bash\" :action ask :origin (:scope global :file \"forged\"))")
    (let ((origin (plist-get (car (gptel-permit--read-notebook-rules)) :origin)))
      (should (equal origin
                     (list :scope 'notebook :file (buffer-file-name)
                           :heading "file level"))))
    ;; Matching is unaffected by the presence (and value) of :origin:
    (goto-char (point-max))
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules nil))
      (should (eq (plist-get (car (gptel-permit--find-action
                                   "id"
                                   (gptel-permit--enrich-tool-call
                                    (list :name "Bash" :args '(:command "ls")))))
                          :action)
                  'ask)))))

(ert-deftest gptel-permit-notebook-org-single-rule-wrapped ()
  "A stored value carrying a single rule is normalized to a one-rule
list; a text-mode buffer with the same content yields no rules."
  ;; Org, single rule (car is a keyword):
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer
       "(:tool \"Bash\" :action allow)")
    (should (= (length (gptel-permit--read-notebook-rules)) 1)))
  ;; Text mode (not org): no property lookup happens
  (gptel-permit-rule-scopes-test--with-notebook
      md
    (should (null (gptel-permit--read-notebook-rules)))))

;; -------------------------------------------------------------------
;; Notebook scope: Org storage (writing)
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-notebook-org-write-round-trip ()
  "Writing a notebook rule lets the reader return it unchanged."
  (gptel-permit-rule-scopes-test--with-notebook
      org
    (let ((rule '(:tool "Bash" :conditions ((:command . "^make")) :action allow)))
      (gptel-permit--write-notebook-rule rule)
      (goto-char (point-max))
      ;; The reader re-attaches its own origin: compare stripped.
      (should (equal (gptel-permit--strip-origin
                      (car (gptel-permit--read-notebook-rules)))
                     rule)))))

(ert-deftest gptel-permit-notebook-org-write-updates-one-property ()
  "A second write updates the one file-level property instead of
adding another."
  (gptel-permit-rule-scopes-test--with-notebook
      org
    (gptel-permit--write-notebook-rule '(:tool "Read" :action allow))
    (gptel-permit--write-notebook-rule '(:tool "Bash" :action ask))
    (goto-char (point-max))
    (should (= (length (gptel-permit--read-notebook-rules)) 2))
    (goto-char (point-min))
    (should (= 1 (count-matches "GPTEL_PERMIT_RULES" (point-min) (point-max))))))

(ert-deftest gptel-permit-notebook-org-write-keeps-heading-value ()
  "A notebook whose only drawer is inside a heading gains a file-level
property and keeps the heading's value unchanged."
  (gptel-permit-rule-scopes-test--with-notebook
      org
    (erase-buffer)
    (insert "* Heading\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:tool \"Read\" :action deny)\n:END:\nbody\n")
    (goto-char (point-max))
    (gptel-permit--write-notebook-rule '(:tool "Bash" :action allow))
    (should (integerp (gptel-permit--notebook-org-file-level-line)))
    ;; The heading's own drawer, read from inside the heading
    ;; (point-min is now a preamble point and sees the file-level one):
    (goto-char (point-max))
    (should (equal (read (org-entry-get (point) "GPTEL_PERMIT_RULES" nil))
                   '(:tool "Read" :action deny)))))

(ert-deftest gptel-permit-notebook-org-write-no-promotion ()
  "Writing from inside a heading whose own property differs does not
copy that heading value into the file-level list."
  (gptel-permit-rule-scopes-test--with-notebook
      org
    (erase-buffer)
    (insert "#+TITLE: t\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:tool \"Read\" :action deny)\n:END:\n\n* Sub\n:PROPERTIES:\n:GPTEL_PERMIT_RULES: (:tool \"Write\" :action allow)\n:END:\nsub body\n")
    (goto-char (point-max))
    (gptel-permit--write-notebook-rule '(:tool "Bash" :action ask))
    (should (equal (read (gptel-permit--notebook-org-file-level-value))
                   ;; the file-level list only: the file-level rule, then
                   ;; the new one; the subtree's Write rule is not copied:
                   '((:tool "Read" :action deny) (:tool "Bash" :action ask))))
    ;; The heading's own property is untouched:
    (goto-char (point-max))
    (should (equal (read (org-entry-get (point) "GPTEL_PERMIT_RULES" nil))
                   '(:tool "Write" :action allow)))))

(ert-deftest gptel-permit-notebook-org-writer-strips-origin ()
  "The writer never writes a `:origin' field into the store."
  (gptel-permit-rule-scopes-test--with-notebook
      org
    (gptel-permit--write-notebook-rule
     (list :tool "Bash" :action 'allow
           :origin (list :scope 'session :file "/somewhere")))
    ;; the stored value is always the list-of-rules form:
    (should (equal (read (gptel-permit--notebook-org-file-level-value))
                   '((:tool "Bash" :action allow))))))

(ert-deftest gptel-permit-notebook-org-writer-notebook-starting-with-heading ()
  "The writer's `org-open-line' dance keeps the drawer out of a
notebook that starts with a heading."
  (gptel-permit-rule-scopes-test--with-notebook
      org
    (erase-buffer)
    (insert "* Top heading\nbody\n")
    (gptel-permit--write-notebook-rule '(:tool "Bash" :action ask))
    (goto-char (point-min))
    (let ((line (gptel-permit--notebook-org-file-level-line)))
      (should line)
      ;; The first actual heading is still "Top heading":
      (goto-char line)
      (outline-next-heading)
      (should (org-at-heading-p))
      (should (equal (org-get-heading t t t t) "Top heading")))))

;; -------------------------------------------------------------------
;; Notebook scope: markdown storage
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-notebook-markdown-safe-local-variable ()
  "The notebook-rules variable is registered as a safe file-local list."
  (should (eq (get 'gptel-permit-notebook-rules 'safe-local-variable) #'listp))
  (should (safe-local-variable-p 'gptel-permit-notebook-rules
                                 '((:tool "B" :action allow)))))

(ert-deftest gptel-permit-notebook-markdown-write-local-variables-block ()
  "Writing in a markdown notebook produces a `Local Variables:' block
naming the variable, and sets the buffer-local value for this session."
  (gptel-permit-rule-scopes-test--with-notebook
      md
    (let ((rule '(:tool "Bash" :conditions ((:command . "^make")) :action allow)))
      (gptel-permit--write-notebook-rule rule)
      (should (equal gptel-permit-notebook-rules (list rule)))
      (let ((text (buffer-string)))
        (should (string-match-p "Local Variables:" text))
        (should (string-match-p "gptel-permit-notebook-rules: ((:tool \"Bash\"" text))))))

(ert-deftest gptel-permit-notebook-markdown-reload-without-prompt ()
  "Re-visiting the written file in a fresh buffer sets the variable to
the written list, with no local-variables prompt."
  (let ((rules-file (make-temp-file "gptel-permit-md-notebook-" nil ".md")))
    (unwind-protect
        (progn
          (with-current-buffer (find-file-noselect rules-file)
            (text-mode)
            (gptel-permit--write-notebook-rule
             '(:tool "Bash" :conditions ((:command . "^make")) :action allow))
            (save-buffer)
            (kill-buffer))
          (let ((buf (find-file-noselect rules-file))
                (prompts 0))
            (unwind-protect
                (with-current-buffer buf
                  (cl-letf (((symbol-function 'yes-or-no-p)
                             (lambda (_q) (cl-incf prompts) nil))
                            ((symbol-function 'y-or-n-p)
                             (lambda (_q) (cl-incf prompts) nil)))
                    (should (equal gptel-permit-notebook-rules
                                   '((:tool "Bash"
                                            :conditions ((:command . "^make"))
                                            :action allow))))
                    ;; The origin names the notebook file:
                    (should (equal (plist-get
                                    (car (gptel-permit--read-notebook-rules))
                                    :origin)
                                   (list :scope 'notebook :file rules-file))))
                  (should (= prompts 0))
                  (set-buffer-modified-p nil))
              (kill-buffer buf))))
      (when (file-exists-p rules-file) (delete-file rules-file)))))

(ert-deftest gptel-permit-notebook-markdown-never-in-org-buffers ()
  "The Org branch never touches the file-local variable mechanism."
  (gptel-permit-rule-scopes-test--with-notebook
      org
    (gptel-permit--write-notebook-rule '(:tool "Bash" :action ask))
    (should (string-match-p "GPTEL_PERMIT_RULES" (buffer-string)))
    (should-not (string-match-p "Local Variables:" (buffer-string)))
    (should-not (string-match-p "gptel-permit-notebook-rules" (buffer-string)))))

(ert-deftest gptel-permit-notebook-markdown-validation-and-origin ()
  "Markdown rules are validated as data (code-shaped ones skipped) and
attested with an origin naming the notebook file."
  (gptel-permit-rule-scopes-test--with-notebook
      md
    (let ((gptel-permit-notebook-rules
           '((:tool "Bash" :action allow)
             (:tool "Bash"
                    :conditions ((:command . (lambda (_v _tc) t)))
                    :action deny))))
      (let ((rules (gptel-permit--read-notebook-rules)))
        (should (= (length rules) 1))
        (should (equal (plist-get (car rules) :origin)
                       (list :scope 'notebook :file (buffer-file-name))))))))

;; -------------------------------------------------------------------
;; Project scope
;; -------------------------------------------------------------------

(ert-deftest gptel-permit-project-read-store ()
  "A project store's rule matches a notebook in the project and
outranks the global rules."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Bash\" :conditions ((:command . \"^make\")) :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((gptel-permit-rules nil)
                  (gptel-permit-global-rules '((:tool "Bash" :action ask))))
              (should (equal (gptel-permit--read-project-rules)
                             (list
                              (list :tool "Bash"
                                    :conditions '((:command . "^make"))
                                    :action 'allow
                                    :origin (list :scope 'project
                                                  :file (expand-file-name
                                                         gptel-permit-store-file-name
                                                         root))))))
              (should (equal (gptel-permit--apply-rules
                              (list :name "Bash" :args '(:command "make test")))
                             '(:confirm nil))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-no-project-no-rules ()
  "With no project and no visited file: no project rules apply, and
the chain is nil."
  (let* ((outside (make-temp-file "gptel-permit-proj-" t))
         (gptel-permit--project-rules-cache nil))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory outside)
          ;; No project resolves here (plain temp dir, no store files).
          (should (null (gptel-permit--project-rules-chain)))
          (should (null (gptel-permit--read-project-rules))))
      (delete-directory outside t))))

(ert-deftest gptel-permit-project-comments-and-forms-parse ()
  "Comments, blank lines and multiple rule forms parse in file order."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store
           root ";; my comments\n(:tool \"Bash\" :action allow)\n\n\n(:tool \"Read\" :action deny)\n;trailing comment\n")
          (should (equal (gptel-permit--parse-project-rules
                          (expand-file-name gptel-permit-store-file-name root))
                         '((:tool "Bash" :action allow) (:tool "Read" :action deny)))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-empty-store-parses-nil ()
  "An empty store parses to no forms."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store root ";; only comments\n\n")
          (should (null (gptel-permit--parse-project-rules
                         (expand-file-name gptel-permit-store-file-name root)))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-parse-dot-form-escapes ()
  "The `#.' read-eval form is unavailable in a store: its syntax error
escapes (nothing is evaluated, nothing is auto-run)."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store root "#.(+ 1 1)\n")
          (should-error
           (gptel-permit--parse-project-rules
            (expand-file-name gptel-permit-store-file-name root))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-disabled-reads-nothing ()
  "With the option off, no store is read and the cache is dropped."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Bash\" :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((gptel-permit-project-rules-enabled t))
              (should (gptel-permit--read-project-rules))
              (should-not (null gptel-permit--project-rules-cache)))
            (let ((gptel-permit-project-rules-enabled nil))
              (should (null (gptel-permit--read-project-rules)))
              (should (null gptel-permit--project-rules-cache)))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-chain-inner-decides-outer-fills ()
  "Chain semantics: the inner store's Bash rule decides over the root
store's Bash ask, while the root store's Read deny still binds."
  (let* ((root (gptel-permit-rule-scopes-test--make-project))
         (sub (expand-file-name "gui" root)))
    (unwind-protect
        (progn
          (mkdir sub t)
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Bash\" :action ask)\n(:tool \"Read\" :action deny)\n")
          (gptel-permit-rule-scopes-test--write-store
           sub "(:tool \"Bash\" :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((buffer-file-name (expand-file-name "notes.org" sub))
                  (gptel-permit-rules nil)
                  (gptel-permit-global-rules nil))
              ;; The chain lists both directories, nearest first.
              (should (equal (gptel-permit--project-rules-chain)
                             (list (file-name-as-directory sub)
                                   (file-name-as-directory root))))
              (let ((result (gptel-permit--find-action
                             "id"
                             (gptel-permit--enrich-tool-call
                              (list :name "Bash" :args '(:command "ls"))))))
                (should (eq (cdr result) 'project))
                (should (equal (plist-get (car result) :action) 'allow)))
              ;; ... while the root store's Read deny decides for Read —
              ;; the inner store simply had nothing to say about Read:
              (let ((result (gptel-permit--find-action
                             "id"
                             (gptel-permit--enrich-tool-call
                              (list :name "Read" :args '(:file_path "x.txt"))))))
                (should (eq (cdr result) 'project))
                (should (equal (plist-get (car result) :action) 'deny))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-store-above-root-not-read ()
  "A store above the project root is not read."
  (let* ((home-parent (gptel-permit-rule-scopes-test--make-project))
         (root (expand-file-name "repo" home-parent))
         (sub (expand-file-name "src" root)))
    (unwind-protect
        (progn
          (mkdir root t)
          (mkdir sub t)
          ;; A store in the directory ABOVE the project root:
          (gptel-permit-rule-scopes-test--write-store
           home-parent "(:tool \"Bash\" :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((buffer-file-name (expand-file-name "n.md" sub))
                  (gptel-permit-rules nil)
                  (gptel-permit-global-rules nil))
              ;; The walk stops at the project root:
              (should (equal (gptel-permit--project-rules-chain)
                             (list (file-name-as-directory sub)
                                   (file-name-as-directory root))))
              (should (null (gptel-permit--apply-rules
                             (list :name "Bash" :args '(:command "ls")))))))
      (delete-directory home-parent t)))))

(ert-deftest gptel-permit-project-broken-subfolder-store-fails-closed ()
  "A broken store anywhere in the chain fails the call closed, even
with a valid root store and a matching global allow."
  (let* ((root (gptel-permit-rule-scopes-test--make-project))
         (sub (expand-file-name "src" root)))
    (unwind-protect
        (progn
          (mkdir sub t)
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Bash\" :action allow)\n")
          (gptel-permit-rule-scopes-test--write-store sub "(broken")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((buffer-file-name (expand-file-name "n.md" sub))
                  (gptel-permit-rules nil)
                  (gptel-permit-global-rules
                   '((:tool "Bash" :action allow))))
              (should (equal (gptel-permit--apply-rules
                              (list :name "Bash" :args '(:command "ls")))
                             '(:confirm t))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-broken-root-store-fails-closed ()
  "An unparseable root store makes the whole hook return (:confirm t)
even with a matching global allow rule — the verdict is asserted, not
merely an error."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store root "(broken")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((gptel-permit-rules nil)
                  (gptel-permit-global-rules '((:tool "Bash" :action allow))))
              (should (equal (gptel-permit--apply-rules
                              (list :name "Bash" :args '(:command "ls")))
                             '(:confirm t))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-cache-avoids-reparse ()
  "An unchanged store is parsed once; a touched store is parsed again."
  (let* ((root (gptel-permit-rule-scopes-test--make-project))
         (real-parse (symbol-function #'gptel-permit--parse-project-rules))
         (parses 0))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Bash\" :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (cl-letf (((symbol-function 'gptel-permit--parse-project-rules)
                       (lambda (file)
                         (cl-incf parses)
                         (funcall real-parse file))))
              (gptel-permit--read-project-rules)
              (gptel-permit--read-project-rules)
              (should (= parses 1))
              ;; Touch the store: picked up on the next call.
              (let ((file (expand-file-name gptel-permit-store-file-name root)))
                (set-file-times file
                                (time-add (current-time)
                                          (seconds-to-time 5))))
              (gptel-permit--read-project-rules)
              (should (= parses 2)))
            (should (equal (gptel-permit--read-project-rules)
                           (list
                            (list :tool "Bash" :action 'allow
                                  :origin (list :scope 'project
                                                :file (expand-file-name
                                                       gptel-permit-store-file-name
                                                       root))))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-write-round-trip-inside-root ()
  "A project rule is appended to the root store (created when
missing); no file outside the project root is touched and nothing else
is created there."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (gptel-permit-rule-scopes-test--with-project root
          (let ((rule '(:tool "Bash" :conditions ((:command . "^make")) :action allow)))
            ;; Creating the store when missing:
            (should (equal (gptel-permit--write-project-rule rule) rule))
            (let ((store (expand-file-name gptel-permit-store-file-name root)))
              (should (file-in-directory-p store root))
              ;; Read-back round trip:
              (let ((read-back (gptel-permit--read-project-rules)))
                (should (= (length read-back) 1))
                (should (equal (gptel-permit--strip-origin (car read-back)) rule))
                (should (equal (plist-get (plist-get (car read-back) :origin)
                                          :file)
                               store)))
              ;; Nothing else appeared in the project root:
              (should (equal (directory-files root)
                             '("." ".." ".gptel-permit-rules"))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-write-appends-not-replaces ()
  "Storing a second project rule appends; existing rules survive."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Read\" :action deny)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (gptel-permit--write-project-rule '(:tool "Bash" :action ask))
            (with-temp-buffer
              (insert-file-contents
               (expand-file-name gptel-permit-store-file-name root))
              (goto-char (point-min))
              (should (= 2 (count-lines (point-min) (point-max)))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-origins-name-stores ()
  "Rules from two stores in one chain carry origins naming their own
store files."
  (let* ((root (gptel-permit-rule-scopes-test--make-project))
         (sub (expand-file-name "gui" root)))
    (unwind-protect
        (progn
          (mkdir sub t)
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Read\" :action deny)\n")
          (gptel-permit-rule-scopes-test--write-store
           sub "(:tool \"Bash\" :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((buffer-file-name (expand-file-name "n.md" sub)))
              (let ((rules (gptel-permit--read-project-rules)))
                (should (= (length rules) 2))
                (should (equal (plist-get (plist-get (car rules) :origin) :file)
                               (expand-file-name gptel-permit-store-file-name sub)))
                (should (equal (plist-get (plist-get (nth 1 rules) :origin) :file)
                               (expand-file-name gptel-permit-store-file-name root)))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-project-write-refused-when-disabled ()
  "A disabled project scope accepts no rules: the writer refuses,
naming the option."
  (let* ((root (gptel-permit-rule-scopes-test--make-project))
         (gptel-permit-project-rules-enabled nil))
    (unwind-protect
        (gptel-permit-rule-scopes-test--with-project root
          (let ((err (should-error (gptel-permit--write-project-rule
                                    '(:tool "Bash" :action allow))
                                   :type 'user-error)))
            (should (string-match-p "gptel-permit-project-rules-enabled"
                                    (error-message-string err))))
          ;; Nothing was written:
          (should-not (file-exists-p
                       (expand-file-name gptel-permit-store-file-name root))))
      (delete-directory root t))))

;; -------------------------------------------------------------------
;; Persisted rules are data, not code (in context)
;; -------------------------------------------------------------------

(defun gptel-permit-rule-scopes-test--always-p (_val _tool-call)
  "A named condition function for persisted rules."
  t)

(ert-deftest gptel-permit-persisted-session-lambda-still-matches ()
  "Session rules are not validated: a lambda condition written in the
user's own configuration still matches (existing behavior)."
  (let ((gptel-permit-rules
         '((:tool "Bash"
                  :conditions ((:command . (lambda (_v _tc) t)))
                  :action allow)))
        (gptel-permit-global-rules nil))
    (should (equal (gptel-permit--apply-rules
                    (list :name "Bash" :args '(:command "ls")))
                   '(:confirm nil)))))

(ert-deftest gptel-permit-persisted-project-lambda-skipped-global-decides ()
  "A lambda condition in a project store is skipped and logged, and a
matching global rule decides the verdict."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Bash\" :conditions ((:command . (lambda (v tc) t))) :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((gptel-permit-rules nil)
                  (gptel-permit-global-rules '((:tool "Bash" :action ask))))
              (should (equal (gptel-permit--apply-rules
                              (list :name "Bash" :args '(:command "ls")))
                             '(:confirm t))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-persisted-named-function-accepted-and-called ()
  "A named function symbol condition in a project store is accepted,
and the named function is called as a condition."
  (let* ((root (gptel-permit-rule-scopes-test--make-project)))
    (unwind-protect
        (progn
          (gptel-permit-rule-scopes-test--write-store
           root "(:tool \"Bash\" :conditions ((:command . gptel-permit-rule-scopes-test--always-p)) :action allow)\n")
          (gptel-permit-rule-scopes-test--with-project root
            (let ((gptel-permit-rules nil)
                  (gptel-permit-global-rules nil))
              (should (equal (gptel-permit--apply-rules
                              (list :name "Bash" :args '(:command "ls")))
                             '(:confirm nil))))))
      (delete-directory root t))))

(ert-deftest gptel-permit-persisted-malformed-notebook-data-isolated ()
  "Malformed forms in a notebook property are skipped; a later valid
rule still matches."
  (gptel-permit-rule-scopes-test--with-org
      (gptel-permit-rule-scopes-test--org-with-file-drawer
       "((not a rule plist) (:tool \"Bash\" :action allow))")
    (let ((gptel-permit-rules nil)
          (gptel-permit-global-rules nil))
      (goto-char (point-max))
      (should (equal (gptel-permit--apply-rules
                      (list :name "Bash" :args '(:command "ls")))
                     '(:confirm nil))))))

(provide 'gptel-permit-rule-scopes-test)
;;; gptel-permit-rule-scopes-test.el ends here
