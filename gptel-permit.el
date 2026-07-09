;;; gptel-permit.el --- Rule-based tool-call permissions for gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>

(defgroup gptel-permit nil
  "Rule-based tool-call permissions for gptel."
  :group 'gptel
  :prefix "gptel-permit-")

(defcustom gptel-permit-log-enabled nil
  "If non-nil, enable extensive logging for gptel-permit permissions check."
  :type 'boolean
  :group 'gptel-permit)

(defun gptel-permit-log (format-string &rest args)
  "Log a message to the `*gptel-permit-log*' buffer if logging is enabled.
FORMAT-STRING and ARGS are passed to `format'."
  (when gptel-permit-log-enabled
    (let ((msg (apply #'format format-string args))
          (buf (get-buffer-create "*gptel-permit-log*")))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ") msg "\n"))))
      (message "gptel-permit: %s" msg))))

(defcustom gptel-permit-global-rules nil
  "Global permission rules for gptel tools.
Each rule is a plist specifying matching conditions for a tool call.
If all conditions of a rule are met, its action is performed.
Global rules are checked after session-local rules.

Example:
  \\='((:tool \"Bash\"
        :conditions ((:command . \"^openspec [^&|;]*$\"))
        :action allow))"
  :type '(repeat
          (plist :key-type symbol
                 :options (((:tool string)
                            (:conditions (repeat (cons symbol string)))
                            (:action (choice (const allow) (const deny) (const ask)))))))
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
  '(("Read"   :tool-group read   :arg-groups ((:file_path . path)))
    ("Glob"   :tool-group read   :arg-groups ((:path . path)))
    ("Grep"   :tool-group read   :arg-groups ((:path . path)))
    ("Write"  :tool-group write  :arg-groups ((:path . path) (:filename . path)))
    ("Edit"   :tool-group write  :arg-groups ((:path . path)))
    ("Insert" :tool-group write  :arg-groups ((:path . path)))
    ("Mkdir"  :tool-group write  :arg-groups ((:parent . path) (:name . path)))
    ("Bash"   :tool-group shell))
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

(defcustom gptel-permit-path-arg-groups '(path)
  "Arg-groups whose values should be expanded with `expand-file-name'.
When matching a regexp against an argument belonging to one of
these groups, the argument value is expanded to an absolute path
before matching."
  :type '(repeat symbol)
  :group 'gptel-permit)


(defun gptel-permit--resolve-tool-group (tool-name)
  "Resolve TOOL-NAME to its tool-group symbol, or nil."
  (when-let* ((entry (assoc tool-name gptel-permit-tool-groups #'equal)))
    (plist-get (cdr entry) :tool-group)))

(defun gptel-permit--resolve-arg-groups (tool-name)
  "Resolve arg keys of TOOL-NAME to an alist of (ARG-KEY . GROUP-SYMBOL).
Returns nil for tools not in the mapping."
  (when-let* ((entry (assoc tool-name gptel-permit-tool-groups #'equal)))
    (plist-get (cdr entry) :arg-groups)))

(defun gptel-permit--arg-group-path-p (group)
  "Return non-nil if GROUP is a path-semantic arg-group."
  (memq group gptel-permit-path-arg-groups))


(defun gptel-permit--resolve-predicate (predicate-keyword arg-key val)
  "Resolve PREDICATE-KEYWORD for ARG-KEY with value VAL.
Returns non-nil if the predicate matches, nil otherwise."
  (let ((normalized (gptel-permit--normalize-arg arg-key val)))
    (cl-case predicate-keyword
      (:inside-project
       (gptel-permit--predicate-inside-project-p normalized))
      (:outside-project
       (not (gptel-permit--predicate-inside-project-p normalized)))
      (:inside-protected-dirs
       (gptel-permit--predicate-inside-protected-dirs-p normalized))
      (:path-traversal
       (gptel-permit--predicate-path-traversal-p normalized arg-key val))
      (t
       (gptel-permit-log "  Unknown predicate `%s` -- failing condition" predicate-keyword)
       nil))))

(defun gptel-permit--predicate-inside-project-p (expanded-path)
  "Return non-nil if EXPANDED-PATH is inside the current project or buffer dir.
Falls back to `default-directory' when neither project nor buffer dir
can be determined."
  (let ((base-dir (or (when-let* ((proj (project-current))
                                  (root (project-root proj)))
                        (expand-file-name root))
                      (and (buffer-file-name)
                           (file-name-directory (buffer-file-name)))
                      default-directory)))
    (and base-dir (file-in-directory-p expanded-path base-dir))))

(defun gptel-permit--predicate-inside-protected-dirs-p (expanded-path)
  "Return non-nil if EXPANDED-PATH is inside any directory in `gptel-permit-protected-dirs'."
  (cl-some (lambda (dir)
             (let ((expanded-dir (expand-file-name dir)))
               (or (file-in-directory-p expanded-path expanded-dir)
                   (file-in-directory-p expanded-dir expanded-path))))
           gptel-permit-protected-dirs))

(defun gptel-permit--predicate-path-traversal-p (_expanded-path arg-key val)
  "Return non-nil if the raw VAL for ARG-KEY contains path traversal elements.
Checks for \"..\" or leading \"/\" in the raw (unexpanded) string value."
  (let ((raw (format "%s" val)))
    (or (string-search ".." raw)
        (string-match-p "^/" raw))))




(defun gptel-permit--normalize-arg (key val &optional tool-name)
  "Normalize argument VAL if KEY represents a file or directory path.
Path detection uses both hardcoded path keys and path-semantic arg-groups
(via TOOL-NAME)."
  (if (or (memq key '(:path :file_path :parent :filepath :filename))
          (and tool-name
               (let ((groups (gptel-permit--resolve-arg-groups tool-name)))
                 (gptel-permit--arg-group-path-p (alist-get key groups)))))
      (expand-file-name (format "%s" val))
    (format "%s" val)))

(defun gptel-permit--match-value-p (arg-key val regexp-or-pred &optional tool-name)
  "Check if VAL for ARG-KEY matches REGEXP-OR-PRED.
If REGEXP-OR-PRED is a keyword, treat it as a predicate.
Otherwise treat it as a regexp string.
TOOL-NAME is used for arg normalization."
  (catch 'gptel-permit--match-value-p
    (unless val
      (gptel-permit-log "  Check: arg `%s` value is nil -> FAILED" arg-key)
      (throw 'gptel-permit--match-value-p nil))
    (if (keywordp regexp-or-pred)
        (let ((result (gptel-permit--resolve-predicate regexp-or-pred arg-key val)))
          (gptel-permit-log "  Check: arg `%s` (value `%s`) against predicate `%s` -> %s"
                            arg-key val regexp-or-pred
                            (if result "SUCCESS" "FAILED"))
          result)
      (let* ((normalized-val
              (gptel-permit--normalize-arg arg-key val tool-name))
             (matched (string-match-p regexp-or-pred normalized-val)))
        (gptel-permit-log "  Check: arg `%s` (value `%s`) against regexp `%s` -> %s"
                          arg-key normalized-val regexp-or-pred
                          (if matched "SUCCESS (matched)" "FAILED (mismatch)"))
        matched))))


(defun gptel-permit--match-condition-p (cond-cell args tool-name)
  "Check if COND-CELL is met by ARGS plist.
COND-CELL is a cons.  If the car is :arg-group, the cdr is
\(GROUP-NAME . REGEXP-OR-PRED) and the condition checks all args
of TOOL-NAME belonging to that group.  Otherwise the car is a
concrete arg keyword and the cdr is REGEXP-OR-PRED.
Return non-nil if matched, nil otherwise."
  (if (eq (car cond-cell) :arg-group)
      ;; Arg-group condition: check any arg in the group
      (let* ((group-cons (cdr cond-cell))
             (group-name (car group-cons))
             (regexp-or-pred (cdr group-cons))
             (arg-groups (gptel-permit--resolve-arg-groups tool-name))
             (matching-args
              (and arg-groups
                   (cl-remove-if-not
                    (lambda (kv) (eq (cdr kv) group-name))
                    arg-groups))))
        (if (null matching-args)
            (progn
              (gptel-permit-log
               "  Check: arg-group `%s` -- tool `%s` has no args in this group -> FAILED"
               group-name tool-name)
              nil)
          (gptel-permit-log
           "  Checking arg-group `%s` across args: %S" group-name
           (mapcar #'car matching-args))
          (cl-some (lambda (kv)
                     (gptel-permit--match-value-p
                      (car kv) (plist-get args (car kv)) regexp-or-pred
                      tool-name))
                   matching-args)))
    ;; Concrete arg condition
    (let* ((arg-key (car cond-cell))
           (regexp-or-pred (cdr cond-cell)))
      (gptel-permit--match-value-p
       arg-key (plist-get args arg-key) regexp-or-pred tool-name))))


(defun gptel-permit--match-rule-p (rule name args)
  "Check if RULE matches tool NAME and ARGS plist.
Return the action if matched, or nil."
  (catch 'gptel-permit--match-rule-p
    (let ((rule-tool (plist-get rule :tool))
          (rule-tool-group (plist-get rule :tool-group))
          (action (plist-get rule :action)))
      (when (and rule-tool rule-tool-group)
        (gptel-permit-log
         "Warning: rule has both :tool `%s` and :tool-group `%s`; using :tool"
         rule-tool rule-tool-group)
        (setq rule-tool-group nil))
      (cond
       (rule-tool
        (unless (equal rule-tool name)
          (gptel-permit-log
           "Skipping rule (tool name mismatch: expected `%s`, got `%s`)"
           rule-tool name)
          (throw 'gptel-permit--match-rule-p nil)))
       (rule-tool-group
        (let ((resolved (gptel-permit--resolve-tool-group name)))
          (unless (eq resolved rule-tool-group)
            (gptel-permit-log
             "Skipping rule (tool-group mismatch: expected `%s`, resolved `%s` for tool `%s`)"
             rule-tool-group resolved name)
            (throw 'gptel-permit--match-rule-p nil))))
       (t nil))
      (gptel-permit-log "Evaluating rule for tool `%s`: %S" name rule)
      (if (cl-every (lambda (cond-cell)
                      (gptel-permit--match-condition-p cond-cell args name))
                    (plist-get rule :conditions))
          (progn
            (gptel-permit-log "Result: Rule matched perfectly. Action: `%s`" action)
            action)
        (gptel-permit-log "Result: Rule did not match (one or more conditions failed).")
        nil))))

(defun gptel-permit--rule-action (name args)
  "Return the action for tool NAME and ARGS from session+global rules.
Returns 'allow, 'deny, 'ask, or nil (no match).
Session-local rules are checked before global rules."
  (let ((all-rules (append gptel-permit-rules gptel-permit-global-rules)))
    (cl-some (lambda (rule) (gptel-permit--match-rule-p rule name args))
             all-rules)))


(defun gptel-permit--validate-error-message (name missing unknown hints spec-args)
  "Build a validation error message for tool NAME.
MISSING is a list of missing arg names, UNKNOWN is a list of unknown
arg names, HINTS is a string of fuzzy suggestions, and SPEC-ARGS is
the tool's argument spec plists."
  (let ((msg-parts nil))
    (when missing
      (push (format "Missing required argument(s) `%s' for tool `%s'"
                    (mapconcat #'identity (nreverse missing) "', `")
                    name)
            msg-parts))
    (when unknown
      (push (format "Unknown argument(s) `%s' provided to tool `%s'"
                    (mapconcat #'identity (nreverse unknown) "', `")
                    name)
            msg-parts))
    (concat (mapconcat #'identity (nreverse msg-parts) "; ")
            hints
            (format "\n    The tool expects these parameter names: %s"
                    (mapconcat (lambda (a)
                                 (concat "`" (plist-get a :name) "'"
                                         (if (plist-get a :optional)
                                             " (optional)" "")))
                               spec-args ", ")))))

(defun gptel-permit--validate-tool-args (hook-plist)
  "Validate HOOK-PLIST structurally before permission rules are evaluated.
HOOK-PLIST is the plist passed to `gptel-pre-tool-call-functions',
containing at minimum :name and :args.  Checks for unknown tool
names, missing required arguments, and unknown argument names."
  (catch 'gptel-permit--validate-tool-args
    (let* ((name (plist-get hook-plist :name))
           (args (plist-get hook-plist :args))
           (tool (ignore-errors (gptel-get-tool name)))
           (spec-args (and tool (gptel-tool-args tool))))
      (unless tool
        (gptel-permit-log "Validation: unknown tool `%s` -> blocked" name)
        (throw 'gptel-permit--validate-tool-args
          (list :block (format "Unknown tool `%s'" name))))
      (when spec-args
        (let* ((missing '())
               (unknown '())
               (spec-arg-names
                (mapcar (lambda (a) (plist-get a :name)) spec-args))
               (provided-keys
                (cl-loop for (k _v) on args by #'cddr
                         collect (substring (symbol-name k) 1))))
          (dolist (arg-spec spec-args)
            (let* ((arg-name (plist-get arg-spec :name))
                   (optional (plist-get arg-spec :optional))
                   (key (intern (concat ":" arg-name)))
                   (value (plist-get args key)))
              (when (and (not optional)
                         (or (null value) (eq value :json-false)))
                (push arg-name missing))))
          (dolist (pk provided-keys)
            (unless (member pk spec-arg-names)
              (push pk unknown)))
          (when (or missing unknown)
            (let ((hints ""))
              (dolist (m missing)
                (when-let* ((p (cl-find-if
                                (lambda (pk)
                                  (and (>= (length pk) 2)
                                       (<= (abs (- (length pk) (length m))) 6)
                                       (or (string-search m pk)
                                           (string-search pk m))))
                                provided-keys)))
                  (setq hints
                        (concat hints
                                (format "\n    You provided `%s' -- did you mean `%s'?"
                                        p m)))))
              (dolist (u unknown)
                (when-let* ((c (cl-find-if
                                (lambda (sn)
                                  (and (>= (length sn) 2)
                                       (<= (abs (- (length sn) (length u))) 8)
                                       (or (string-search u sn)
                                           (string-search sn u))))
                                spec-arg-names)))
                  (setq hints
                        (concat hints
                                (format "\n    You provided `%s' -- did you mean `%s'?"
                                        u c)))))
              (gptel-permit-log "Validation: %s -> blocked"
                                (if missing
                                    (format "missing %s" (car (nreverse missing)))
                                  (format "unknown args %s" (car (nreverse unknown)))))
              (throw 'gptel-permit--validate-tool-args
                (list :block
                      (gptel-permit--validate-error-message
                       name missing unknown hints spec-args))))))))))


(defun gptel-permit-pre-tool-security-hook (tool-call)
  "Enforce permission rules for TOOL-CALL.
Session-local rules are checked first, then global rules.
Returns a plist with :confirm, :block, or nil (fallback)."
  (catch 'gptel-permit-pre-tool-security-hook
    (let* ((name (plist-get tool-call :name))
           (args (plist-get tool-call :args)))
      (when (or (plist-get tool-call :result)
                (plist-get tool-call :error))
        (gptel-permit-log "Skipping tool `%s` (already processed by earlier hook)" name)
        (throw 'gptel-permit-pre-tool-security-hook nil))
      (gptel-permit-log "Checking permissions for tool call `%s` with args: %S" name args)
      (let ((action (gptel-permit--rule-action name args)))
        (pcase action
          ('allow
           (gptel-permit-log "Resulting Decision: ACCEPT (action: allow) -> :confirm nil")
           '(:confirm nil))
          ('deny
           (gptel-permit-log "Resulting Decision: REJECT (action: deny) -> auto-denied :block")
           (list :block (format "Tool %s execution was auto-denied by user permission rules." name)))
          ('ask
           (gptel-permit-log "Resulting Decision: ASK (action: ask) -> :confirm t")
           '(:confirm t))
          (_
           (gptel-permit-log "Resulting Decision: FALLBACK (no rules matched) -> defer to default confirm function")
           nil))))))

(defun gptel-permit--rule-action-for-call (tool-spec arg-plist)
  "Get the matched rule action for TOOL-SPEC and ARG-PLIST, if any."
  (gptel-permit--rule-action (gptel-tool-name tool-spec) arg-plist))

(defun gptel-permit--select-tool-and-arg (tool-calls)
  "Prompt the user to select a tool call from TOOL-CALLS and one of its arguments.
Return a cons of (tool-call . arg-name) or nil."
  (when tool-calls
    (let* ((tool-call
            (if (= (length tool-calls) 1)
                (car tool-calls)
              (let* ((names (mapcar (lambda (tc) (gptel-tool-name (car tc))) tool-calls))
                     (chosen (completing-read "Select tool for rule: " names nil t)))
                (cl-find-if (lambda (tc) (equal (gptel-tool-name (car tc)) chosen)) tool-calls))))
           (tool-spec (car tool-call))
           (arg-plist (cadr tool-call))
           (arg-names (cl-loop for key in arg-plist by #'cddr
                               collect (substring (symbol-name key) 1))))
      (if (null arg-names)
          (progn
            (message "Tool %s has no arguments to match." (gptel-tool-name tool-spec))
            nil)
        (let ((chosen-arg (completing-read "Select argument to match: " arg-names nil t)))
          (cons tool-call (intern (concat ":" chosen-arg))))))))

;;;###autoload
(defun gptel-permit-confirm-or-add-rule (&optional tool-calls ov)
  "Accept tool-calls or prompt to create a rule first if called with prefix arg."
  (interactive
   (pcase-let ((`(,resp . ,o) (get-char-property-and-overlay
                               (point) 'gptel-tool)))
     (list resp o)))
  (if tool-calls
      (pcase-let* ((selection (gptel-permit--select-tool-and-arg tool-calls))
                   (tool-call (car selection))
                   (arg-key (cdr selection)))
        (if (not tool-call)
            (message "No tool call selected.")
          (let* ((tool-spec (car tool-call))
                 (arg-plist (cadr tool-call))
                 (tool-name (gptel-tool-name tool-spec))
                 (current-val (plist-get arg-plist arg-key))
                 (normalized-val (gptel-permit--normalize-arg arg-key current-val tool-name))
                 (regexp (read-regexp
                          (format "Regexp to match %s arg %s (current: %s): "
                                  tool-name arg-key normalized-val)))
                 (action-str (completing-read "Action when matched: " '("allow" "deny" "ask") nil t nil nil "allow"))
                 (action (intern action-str)))
            (push (list :tool tool-name
                        :conditions (list (cons arg-key regexp))
                        :action action)
                  gptel-permit-rules)
            (message "Added rule: tool %s, %s matching %s -> %s"
                     tool-name arg-key regexp action-str)
            (pcase-let ((`(,denied-calls ,allowed-calls)
                         (cl-loop for tc in tool-calls
                                  if (eq (gptel-permit--rule-action-for-call (car tc) (cadr tc)) 'deny)
                                  collect tc into denied
                                  else collect tc into allowed
                                  finally return (list denied allowed))))
              (dolist (tc denied-calls)
                (let* ((ts (car tc))
                       (cb (cl-caddr tc))
                       (name (gptel-tool-name ts)))
                  (funcall cb (format "<tool_call_error>\nTool %s execution was auto-denied by user permission rules.\n</tool_call_error>" name))))
              (if allowed-calls
                  (gptel--accept-tool-calls allowed-calls ov)
                (when (and (overlayp ov) (overlay-buffer ov))
                  (with-current-buffer (overlay-buffer ov)
                    (when-let* ((preview-handles (overlay-get ov 'previews)))
                      (dolist (func-to-handle preview-handles)
                        (when (car func-to-handle) (apply func-to-handle))))
                    (dolist (prompt-ov (overlay-get ov 'prompt))
                      (when-let* (((overlay-buffer prompt-ov))
                                  (inhibit-read-only t))
                        (delete-region (overlay-start prompt-ov)
                                       (overlay-end prompt-ov)))))
                  (delete-overlay ov)))))))
    (gptel--accept-tool-calls tool-calls ov)))

;;;###autoload
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
        (add-hook 'gptel-pre-tool-call-functions
                  #'gptel-permit--validate-tool-args t)
        (add-hook 'gptel-pre-tool-call-functions
                  #'gptel-permit-pre-tool-security-hook t)
        (keymap-set gptel-tool-call-actions-map "C-c C-b"
                    #'gptel-permit-confirm-or-add-rule))
    (remove-hook 'gptel-pre-tool-call-functions
                 #'gptel-permit--validate-tool-args)
    (remove-hook 'gptel-pre-tool-call-functions
                 #'gptel-permit-pre-tool-security-hook)
    (keymap-unset gptel-tool-call-actions-map "C-c C-b")))
















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

(provide 'gptel-permit)
;;; gptel-permit.el ends here
