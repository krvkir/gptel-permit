;;; gptel-permit.el --- Rule-based tool-call permissions for gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9"))
;; Keywords: convenience, tools, agents, hypermedia
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; This file provides a permission rule system for gptel tools.
;; Rules can be defined globally via custom variables or interactively
;; per session (buffer-local).

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'project)

(declare-function gptel-tool-p "gptel-request" (object))
(declare-function gptel-tool-name "gptel-request" (tool))

(defgroup gptel-permit nil
  "Rule-based tool-call permissions for gptel."
  :group 'gptel
  :prefix "gptel-permit-")

(defcustom gptel-permit-log-enabled nil
  "If non-nil, enable extensive logging for gptel-permit permissions check."
  :type 'boolean
  :group 'gptel-permit)

(defun gptel-permit--log (format-string &rest args)
  "Log a message to the `*gptel-permit-log*' buffer if logging is enabled.
FORMAT-STRING and ARGS are passed to `format'."
  (when gptel-permit-log-enabled
    (let ((msg (apply #'format format-string args))
          (buf (get-buffer-create "*gptel-permit-log*")))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ") msg "\n")))))))

(defun gptel-permit--truncate-arg (arg)
  "Truncate string representation of ARG to first 30 and last 30 characters if it's longer than 60."
  (let ((s (format "%s" arg)))
    (if (> (length s) 60)
        (concat (substring s 0 30) "..." (substring s -30))
      s)))

(defcustom gptel-permit-global-rules
  '((:tool-group read
                 :conditions ((path . :inside-project))
                 :action allow)
    (:tool-group write
                 :conditions ((path . :inside-project))
                 :action ask)
    (:tool-group write
                 :conditions ((path . :path-traversal))
                 :action ask)
    (:tool-group search :action allow)
    (:conditions ((path . :inside-protected-dirs))
                 :action ask)
    (:tool "Bash"
           :conditions ((:command . ".* rm .*"))
           :action ask)
    (:action ask))
  "Global permission rules for gptel tools.

Each rule is a plist specifying matching conditions for a tool
call.  If all conditions of a rule are met, its action is
performed.  Global rules are checked after session-local rules
(see `gptel-permit-rules').

A rule may contain the following keys:
  :tool         A concrete tool name (string).
  :tool-group   A tool group symbol (e.g. read, write, shell).
  :conditions   An alist of (KEY . PATTERN) pairs.
  :action       One of allow, deny, or ask.

If both :tool and :tool-group are present, :tool takes
precedence and a warning is emitted.  If neither :tool nor
:tool-group is present, the rule matches ANY tool.

Each condition KEY can be:
  - A concrete argument name keyword (e.g. :file_path, :command).
  - An argument group symbol
    (e.g. (path . \"regexp\")).

Each condition PATTERN can be:
  - A regexp string tested against the normalized argument value.
  - A predicate keyword (:inside-project, :outside-project,
    :inside-protected-dirs, :path-traversal).

Default rules:
  - Auto-allow read tools accessing paths inside the project.
  - Ask for write tools accessing paths inside the project.
  - Ask for write tools with path-traversal (.. or absolute).
  - Ask for any tool accessing protected directories.

Customize this variable or override it in your init file."
  :type '(repeat
          (plist
           :key-type symbol
           :value-type sexp
           :options ((:tool string)
                     (:tool-group symbol)
                     (:conditions (repeat
                                   (cons
                                    (choice (symbol :tag "Argument group")
                                            (symbol :tag "Argument name"))
                                    (choice :tag "Rule condition"
                                            (string :tag "Regexp")
                                            (const :inside-project)
                                            (const :outside-project)
                                            (const :inside-protected-dirs)
                                            (const :path-traversal)))))
                     (:action
                      (choice (const :tag "Allow (auto-approve)" allow)
                              (const :tag "Deny (auto-block)" deny)
                              (const :tag "Ask (prompt user)" ask))))))
  :group 'gptel-permit)

(defvar-local gptel-permit-rules nil
  "List of session-local permission rules for gptel tools in the current session.
Each rule is a plist of the form:
  (:tool <tool-name> :conditions ((<arg-name> . <regexp>) ...) :action <allow/deny/ask>)")

(defcustom gptel-permit-protected-dirs '("~/.ssh/" "~/.gnupg/")
  "Directories that always require confirmation for tool-call access.
Used by the `:inside-protected-dirs' predicate in permission rules."
  :type '(repeat directory)
  :group 'gptel-permit)

(defcustom gptel-permit-tool-groups
  '(("Read" :tool-group read :arg-groups ((:file_path . path)))
    ("Glob" :tool-group read :arg-groups ((:path . path)))
    ("Grep" :tool-group read :arg-groups ((:path . path)))
    ("Write" :tool-group write :arg-groups ((:path . path) (:filename . path)))
    ("Edit" :tool-group write :arg-groups ((:path . path)))
    ("Insert" :tool-group write :arg-groups ((:path . path)))
    ("Mkdir" :tool-group write :arg-groups ((:parent . path) (:name . path)))
    ("Bash" :tool-group execute)
    ("Eval" :tool-group execute)
    ("WebSearch" :tool-group search)
    ("WebFetch" :tool-group search)
    ("YouTube" :tool-group search)
    ("Skill" :tool-group search)
    ("symbol_exists" :tool-group search)
    ("load_paths" :tool-group search)
    ("features" :tool-group search)
    ("manual_names" :tool-group search)
    ("manual_nodes" :tool-group search)
    ("manual_node_contents" :tool-group search)
    ("library_source" :tool-group search)
    ("symbol_manual_section" :tool-group search)
    ("function_source" :tool-group search)
    ("variable_source" :tool-group search)
    ("variable_value" :tool-group read)
    ("function_documentation" :tool-group search)
    ("variable_documentation" :tool-group search)
    ("variable_completions" :tool-group search)
    ("function_completions" :tool-group search)
    ("command_completions" :tool-group search)
    ("variable_prefix" :tool-group search))
  "Mapping of tool names to tool-groups and argument-groups.

Each entry is a list: (TOOL-NAME :tool-group GROUP :arg-groups ((ARG . GROUP) ...)).
Both :tool-group and :arg-groups are optional.

When a rule targets a tool-group, it matches any tool belonging to that group.
When a rule targets an arg-group, it matches any argument of the tool
belonging to that group."
  :type '(alist :key-type string
                :value-type (plist :key-type symbol
                                   :options ((:tool-group symbol)
                                             (:arg-groups (alist :key-type symbol
                                                                 :value-type symbol)))))
  :group 'gptel-permit)

(defun gptel-permit--resolve-tool-group (tool-name)
  "Resolve TOOL-NAME to its :tool-group."
  (plist-get (cdr (assoc tool-name gptel-permit-tool-groups)) :tool-group))

(defun gptel-permit--resolve-arg-groups (tool-name)
  "Resolve TOOL-NAME to its :arg-groups."
  (plist-get (cdr (assoc tool-name gptel-permit-tool-groups)) :arg-groups))

(defun gptel-permit--get-tool (name)
  "Retrieve the gptel tool spec for NAME, fallback to `gptel-tools`."
  (ignore-errors
    (if (fboundp 'gptel-get-tool)
        (gptel-get-tool name)
      (alist-get name gptel-tools nil nil #'equal))))

(defun gptel-permit--project-root ()
  "Get the current project root or active buffer's directory."
  (let ((pr (project-current))
        (bfn (buffer-file-name)))
    (or (and pr (project-root pr))
        (and bfn (file-name-directory bfn)))))

(defun gptel-permit--processed-p (tool-call)
  "Return non-nil if TOOL-CALL has already been processed or errored."
  (or (plist-member tool-call :result)
      (plist-member tool-call :error)
      (plist-get tool-call :result)
      (plist-get tool-call :error)))

(defun gptel-permit--path-arg-p (arg-key arg-groups)
  "Return non-nil if ARG-KEY belongs to the `path' arg-group."
  (eq (alist-get arg-key arg-groups) 'path))

(defun gptel-permit--tool-path-args (tool-name arg-groups)
  "Get all argument keywords (as strings) that are path arguments for TOOL-NAME."
  (let* ((tool (gptel-permit--get-tool tool-name))
         (spec-args (and tool (gptel-tool-args tool))))
    (cl-loop for spec-arg in spec-args
             for arg-str = (plist-get spec-arg :name)
             for arg-kw = (intern (concat ":" arg-str))
             when (gptel-permit--path-arg-p arg-kw arg-groups)
             collect (concat ":" arg-str))))


(defun gptel-permit--normalize-tool-call (tool-call)
  "Normalize TOOL-CALL from overlay format to plist format."
  (if (and (listp tool-call)
           (not (keywordp (car tool-call)))
           (fboundp 'gptel-tool-p)
           (gptel-tool-p (car tool-call)))
      (list :name (gptel-tool-name (car tool-call))
            :args (cadr tool-call))
    tool-call))

(defun gptel-permit--enrich-tool-call (tool-call)
  "Enrich TOOL-CALL with :tool-group and :arg-groups."
  (let* ((name (plist-get tool-call :name))
         (group-info (cdr (assoc name gptel-permit-tool-groups)))
         (tool-group (plist-get group-info :tool-group))
         (arg-groups (plist-get group-info :arg-groups)))
    (append tool-call (list :tool-group tool-group :arg-groups arg-groups))))

(defun gptel-permit--validate-args (tool-call)
  "Validate TOOL-CALL before permission rules are evaluated.
TOOL-CALL is the plist passed to `gptel-pre-tool-call-functions',
containing at minimum :name and :args.  Checks for unknown tool
names, missing required arguments, and unknown argument names."
  (unless (gptel-permit--processed-p tool-call)
    (let* ((name (plist-get tool-call :name))
           (args (plist-get tool-call :args))
           (trunc-args (cl-loop for (k v) on args by #'cddr
                                collect k collect (gptel-permit--truncate-arg v))))
      (gptel-permit--log "Started validation for tool: %s with args: %S" name trunc-args)
      (let ((tool (gptel-permit--get-tool name)))
        (if (not tool)
            (progn
              (gptel-permit--log "Verdict: Blocked (Unknown tool: %s)" name)
              (list :block (format "Unknown tool: %s" name)))
          (let* ((spec-args (gptel-tool-args tool))
                 (spec-arg-names (mapcar (lambda (a) (intern (concat ":" (plist-get a :name)))) spec-args))
                 (missing nil)
                 (unknown nil))
            (cl-loop for (k _v) on args by #'cddr do
                     (if (memq k spec-arg-names)
                         (gptel-permit--log "Argument %s provided: ok" k)
                       (progn
                         (gptel-permit--log "Argument %s provided: wrong (unknown argument)" k)
                         (push (symbol-name k) unknown))))
            (dolist (spec-arg spec-args)
              (let* ((arg-name (intern (concat ":" (plist-get spec-arg :name))))
                     (optional (plist-get spec-arg :optional))
                     (val (plist-get args arg-name)))
                (when (and (not optional)
                           (or (not (plist-member args arg-name))
                               (null val)))
                  (gptel-permit--log "Argument %s missing (required)" arg-name)
                  (push (plist-get spec-arg :name) missing))))
            (let ((msg-parts nil))
              (when missing
                (push (format "Missing required argument(s): %s" (mapconcat #'identity missing ", ")) msg-parts))
              (when unknown
                (push (format "Unknown argument(s): %s (Did you mean %s?)" 
                              (mapconcat #'identity unknown ", ")
                              (mapconcat (lambda (a) (plist-get a :name)) spec-args ", "))
                      msg-parts))
              (if msg-parts
                  (let ((msg (mapconcat #'identity (nreverse msg-parts) "; ")))
                    (gptel-permit--log "Verdict: Blocked (%s)" msg)
                    (list :block msg))
                (progn
                  (gptel-permit--log "Verdict: Validation passed")
                  nil)))))))))

(defun gptel-permit--match-rule-p (rule tool-call)
  "Match RULE against enriched TOOL-CALL.
Returns the rule's :action if matched, otherwise nil."
  (let ((name (plist-get tool-call :name))
        (args (plist-get tool-call :args))
        (tool-group (plist-get tool-call :tool-group))
        (arg-groups (plist-get tool-call :arg-groups))
        (rule-tool (plist-get rule :tool))
        (rule-tool-group (plist-get rule :tool-group))
        (conditions (plist-get rule :conditions))
        (action (plist-get rule :action)))
    (when (and rule-tool rule-tool-group)
      (gptel-permit--log "Warning: Both :tool and :tool-group present in rule."))
    (let ((reason (cond ((and rule-tool (equal rule-tool name)) "tool name match")
                        ((and (not rule-tool) rule-tool-group (equal rule-tool-group tool-group)) "tool group match")
                        ((and (not rule-tool) (not rule-tool-group)) "universal rule"))))
      (when reason
        (gptel-permit--log "Testing rule (reason: %s): %S" reason rule)
        (let ((match (cl-every
                      (lambda (cond-pair)
                        (let* ((key (car cond-pair))
                               (val (cdr cond-pair))
                               (arg-keys (if (keywordp key) (list key)
                                           (cl-loop for (k . g) in arg-groups if (eq g key) collect k))))
                          (and arg-keys
                               (cl-some
                                (lambda (ak)
                                  (let* ((arg-val (plist-get args ak))
                                         (is-path (or (eq key 'path) (gptel-permit--path-arg-p ak arg-groups)))
                                         (effective-val (if (and is-path (null arg-val)) "" arg-val)))
                                    (and effective-val
                                         (let ((expanded (if is-path (expand-file-name effective-val) effective-val)))
                                           (cond
                                            ((stringp val) (string-match-p val (format "%s" expanded)))
                                            ((eq val :path-traversal) (string-match-p "\\(?:^/\\|\\.\\.\\)" (format "%s" effective-val)))
                                            ((eq val :inside-project)
                                             (let ((root (gptel-permit--project-root)))
                                               (and root (file-in-directory-p (format "%s" expanded) root))))
                                            ((eq val :outside-project)
                                             (let ((root (gptel-permit--project-root)))
                                               (and root (not (file-in-directory-p (format "%s" expanded) root)))))
                                            ((eq val :inside-protected-dirs)
                                             (cl-some (lambda (d) (let ((pd (expand-file-name d)) (tg (format "%s" expanded))) (or (file-in-directory-p tg pd) (file-in-directory-p pd tg)))) gptel-permit-protected-dirs))
                                            (t (gptel-permit--log "Unknown condition predicate: %s" val) nil))))))
                                arg-keys))))
                      conditions)))
          (when match
            (gptel-permit--log "Rule matched!")
            action))))))

(defun gptel-permit--rule-action (tool-call)
  "Evaluate rules for TOOL-CALL and return action, or nil."
  (let ((rules (append gptel-permit-rules gptel-permit-global-rules))
        (action nil))
    (catch 'found
      (dolist (rule rules)
        (let ((act (gptel-permit--match-rule-p rule tool-call)))
          (when act
            (setq action act)
            (throw 'found t)))))
    action))

(defun gptel-permit--apply-rules (tool-call)
  "Enforce permission rules for TOOL-CALL.
Session-local rules are checked first, then global rules.
Returns a plist with :confirm, :block, or nil (fallback)."
  (unless (gptel-permit--processed-p tool-call)
    (let* ((enriched (gptel-permit--enrich-tool-call tool-call))
           (name (plist-get enriched :name))
           (args (plist-get enriched :args))
           (trunc-args (cl-loop for (k v) on args by #'cddr
                                collect k collect (gptel-permit--truncate-arg v))))
      (gptel-permit--log "Started rule checks for tool: %s with args: %S" name trunc-args)
      (let ((action (gptel-permit--rule-action enriched)))
        (gptel-permit--log "Verdict: %s" (or action "none (fallback)"))
        (pcase action
          ('allow (list :confirm nil))
          ('deny  (list :block "auto-denied"))
          ('ask   (list :confirm t))
          (_      nil))))))

;;;###autoload
(defun gptel-permit-add-rule (&optional tool-calls ov)
  "Prompt to create a rule, then apply it to all the TOOL-CALLS in current pack."
  (interactive (pcase-let ((`(,resp . ,o) (get-char-property-and-overlay
                                           (point) 'gptel-tool)))
                 (list resp o)))
  (unless tool-calls
    ;; Fallback for interactive use outside the overlay, though normally called via keymap
    (user-error "No tool-calls provided to create a rule for"))
  (let* ((normalized-tool-calls (mapcar #'gptel-permit--normalize-tool-call tool-calls)))
    (gptel-permit--log "Started rule addition. Active tool calls: %S" 
                       (mapcar (lambda (tc) (plist-get tc :name)) normalized-tool-calls))
    (let* ((tool-call (car normalized-tool-calls))
           (enriched (gptel-permit--enrich-tool-call tool-call))
           (name (plist-get enriched :name))
           (args (plist-get enriched :args))
           (tool-group (plist-get enriched :tool-group))
           (arg-groups (plist-get enriched :arg-groups))
           (rule (list))
           (conditions nil))
      (gptel-permit--log "Using tool call: %s (group: %s). Args found: %S. Arg groups: %S" 
                         name tool-group
                         (cl-loop for (k v) on args by #'cddr collect k
                                  collect (gptel-permit--truncate-arg v)) arg-groups)
      (if (and tool-group
               (y-or-n-p (format "Tool '%s' belongs to group '%s'. Target the entire group?"
                                 name tool-group)))
          (setq rule (plist-put rule :tool-group tool-group))
        (setq rule (plist-put rule :tool name)))
      (catch 'done
        (while t
          (let* ((arg-keys (cl-loop for (k _v) on args by #'cddr collect (symbol-name k)))
                 (path-spec-args (gptel-permit--tool-path-args name arg-groups))
                 (all-possible-args (cl-delete-duplicates
                                     (append arg-keys path-spec-args)
                                     :test #'string=))
                 (choices (append all-possible-args '("DONE")))
                 (choice (completing-read "Select argument to match (or DONE): " choices)))
            (if (string= choice "DONE")
                (throw 'done t)
              (let* ((arg-kw (intern choice))
                     (arg-val (plist-get args arg-kw))
                     (arg-group (alist-get arg-kw arg-groups))
                     (target arg-kw))
                (when (and arg-group
                           (y-or-n-p (format "Argument '%s' belongs to group '%s'. Target the entire group?" choice arg-group)))
                  (setq target arg-group))
                (let* ((default-re (if arg-val (format "^%s$" (regexp-quote (format "%s" arg-val))) ""))
                       (re (read-string (format "Regexp for %s: " target) default-re)))
                  (push (cons target re) conditions)
                  (gptel-permit--log "Added condition: %s matches %S" target re)))))))
      (setq rule (plist-put rule :conditions (nreverse conditions)))
      (let ((action (intern (completing-read "Action: " '("allow" "ask" "deny") nil t))))
        (setq rule (plist-put rule :action action)))
      (push rule gptel-permit-rules)
      (gptel-permit--log "Resulting rule: %S" rule)
      (message "Rule added: %S" rule)
      (when (fboundp 'gptel--accept-tool-calls)
        (gptel--accept-tool-calls tool-calls ov)))))

;;;###autoload
(define-minor-mode gptel-permit-mode
  "Minor mode for rule-based tool-call permissions in gptel.
When enabled, registers validation and permission hooks on
`gptel-pre-tool-call-functions' and binds `C-c C-b' in
`gptel-tool-call-actions-map' for interactive rule creation."
  :global t
  :lighter " Permit"
  (if gptel-permit-mode
      (progn
        (add-hook 'gptel-pre-tool-call-functions #'gptel-permit--validate-args t)
        (add-hook 'gptel-pre-tool-call-functions #'gptel-permit--apply-rules t)
        (keymap-set gptel-tool-call-actions-map "C-c C-b" #'gptel-permit-add-rule))
    (remove-hook 'gptel-pre-tool-call-functions #'gptel-permit--validate-args)
    (remove-hook 'gptel-pre-tool-call-functions #'gptel-permit--apply-rules)
    (keymap-unset gptel-tool-call-actions-map "C-c C-b")))

(provide 'gptel-permit)
;;; gptel-permit.el ends here
