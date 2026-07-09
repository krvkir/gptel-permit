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
;;
;; Rules are of the form:
;;   (:tool <tool-name> :conditions ((<arg-name> . <regexp>) ...) :action <'allow or 'deny or 'ask>)

;;; Code:

(require 'cl-lib)
(require 'gptel)

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

(defun gptel-permit--normalize-arg (key val)
  "Normalize argument VAL if KEY represents a file or directory path."
  (if (memq key '(:path :file_path :parent :filepath :filename))
      (expand-file-name (format "%s" val))
    (format "%s" val)))

(defun gptel-permit--match-condition-p (cond-cell args)
  "Check if COND-CELL is met by ARGS plist and log the check.
COND-CELL is a cons of (ARG-KEY . REGEXP).
Return non-nil if matched, nil otherwise."
  (let* ((arg-key (car cond-cell))
         (regexp (cdr cond-cell))
         (val (plist-get args arg-key))
         (normalized-val (and val (gptel-permit--normalize-arg arg-key val)))
         (matched (and val (string-match-p regexp normalized-val))))
    (gptel-permit-log "  Check: arg `%s` (value `%s`) against regexp `%s` -> %s"
                      arg-key
                      (or normalized-val "nil")
                      regexp
                      (if matched "SUCCESS (matched)" "FAILED (mismatch)"))
    matched))

(defun gptel-permit--match-rule-p (rule name args)
  "Check if RULE matches tool NAME and ARGS plist.
Return the action if matched, or nil."
  (let ((rule-tool (plist-get rule :tool))
        (action (plist-get rule :action)))
    (if (not (equal rule-tool name))
        (progn
          (gptel-permit-log "Skipping rule (tool name mismatch: expected `%s`, got `%s`)"
                            rule-tool name)
          nil)
      (gptel-permit-log "Evaluating rule for tool `%s`: %S" name rule)
      (if (cl-every (lambda (cond-cell)
                      (gptel-permit--match-condition-p cond-cell args))
                    (plist-get rule :conditions))
          (progn
            (gptel-permit-log "Result: Rule matched perfectly. Action: `%s`" action)
            action)
        (gptel-permit-log "Result: Rule did not match (one or more conditions failed).")
        nil))))

(defun gptel-permit-pre-tool-security-hook (tool-call)
  "Enforce security guards and session-local permission rules for TOOL-CALL."
  (let* ((name (plist-get tool-call :name))
         (args (plist-get tool-call :args))
         ;; 1. Hard Security Guard: Prevent path traversal bypasses
         (traversal-p
          (cond
           ((equal name "Write")
            (let ((filename (plist-get args :filename)))
              (and filename (or (string-search ".." filename) (string-match-p "^/" filename)))))
           ((equal name "Mkdir")
            (let ((subname (plist-get args :name)))
              (and subname (or (string-search ".." subname) (string-match-p "^/" subname)))))
           (t nil))))
    (gptel-permit-log "Checking permissions for tool call `%s` with args: %S" name args)
    (if traversal-p
        ;; Block the traversal attempt outright and inform the LLM of the violation
        (progn
          (gptel-permit-log "Security violation: Path traversal elements detected in Write/Mkdir. Result: BLOCKED")
          (list :block "Security Violation: Path traversal elements ('..' or leading '/') are strictly prohibited."))
      ;; 2. Session & Global Rule Matching
      (gptel-permit-log "No path traversal security violations. Matching rules...")
      (let* ((all-rules (append gptel-permit-rules gptel-permit-global-rules))
             (action (cl-some (lambda (rule) (gptel-permit--match-rule-p rule name args))
                              all-rules)))
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
          ;; 3. Fallback: Return nil so gptel runs the default tool :confirm functions
          (_
           (gptel-permit-log "Resulting Decision: FALLBACK (no rules matched) -> defer to default confirm function")
           nil))))))

(defun gptel-permit--rule-action-for-call (tool-spec arg-plist)
  "Get the matched rule action for TOOL-SPEC and ARG-PLIST, if any."
  (let ((all-rules (append gptel-permit-rules gptel-permit-global-rules)))
    (cl-some (lambda (rule)
               (gptel-permit--match-rule-p rule (gptel-tool-name tool-spec) arg-plist))
             all-rules)))

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
                 (normalized-val (gptel-permit--normalize-arg arg-key current-val))
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

;; Automatically register our custom abnormal hook
(add-hook 'gptel-pre-tool-call-functions #'gptel-permit-pre-tool-security-hook)

(keymap-set gptel-tool-call-actions-map "C-c C-b" #'gptel-permit-confirm-or-add-rule)

(provide 'gptel-permit)
;;; gptel-permit.el ends here
