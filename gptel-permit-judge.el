;;; gptel-permit-judge.el --- LLM-as-a-judge condition for gptel-permit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.0.1"))
;; Keywords: convenience, tools, agents, security
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; An LLM-as-a-judge condition for gptel-permit rules.  The judge asks a
;; small local model whether a grey-zone tool call (e.g. a Bash command)
;; has a blast radius confined to the project and is safe to auto-allow.
;; The judge is deny-only: it returns a boolean for use as a :conditions
;; value, and never produces a :block verdict.  All failure paths return
;; nil, so the enclosing rule does not match and evaluation falls through
;; to the next rule (normally ask).  See `gptel-permit-judge-safe-p'.
;;
;; Rationale: deterministic deny rules must remain ahead of judge rules;
;; per-call classifiers are blind to multi-hop exploit chains (cf. Embrace
;; The Red's break of Claude Code auto mode), so the judge is a
;; friction-reducer, not a security boundary.

;;; Code:

(require 'gptel)
(require 'gptel-permit)

(defgroup gptel-permit-judge nil
  "LLM-as-a-judge condition for gptel-permit."
  :group 'gptel-permit
  :prefix "gptel-permit-judge-")

(defcustom gptel-permit-judge-backend nil
  "Name of the gptel backend used for judging, or nil to disable.
When nil, `gptel-permit-judge-safe-p' returns nil without a request."
  :type '(choice (const :tag "Disabled" nil) (string :tag "Backend name"))
  :group 'gptel-permit-judge)

(defcustom gptel-permit-judge-model nil
  "Model name (string) passed to the judge backend."
  :type '(choice (const nil) string)
  :group 'gptel-permit-judge)

(defcustom gptel-permit-judge-timeout 15
  "Seconds to wait for a judge response before giving up."
  :type 'integer
  :group 'gptel-permit-judge)

(defcustom gptel-permit-judge-policy ""
  "Extra prose policy appended to the fixed judge preamble (user-tunable)."
  :type 'string
  :group 'gptel-permit-judge)

(defcustom gptel-permit-judge-history-entries 0
  "Number of recent buffer entries to include in the judge prompt.
0 (default) means no conversation history is sent to the judge; only the
policy preamble and the tool-call details are sent.  When positive, the
last N entries from the tool call's buffer are included, each truncated."
  :type 'integer
  :group 'gptel-permit-judge)

(defvar-local gptel-permit--last-judge-rationale nil
  "Rationale from the most recent judge verdict in this buffer.
Set by `gptel-permit-judge-safe-p'; intended for audit/analytics.")

(defconst gptel-permit--judge-preamble
  "You are a security classifier for tool calls made by an AI coding agent.
Decide whether the TOOL CALL below is obviously safe to run unattended.
A call is SAFE only when its effect is confined to the project directory or
a temporary folder, modifies no system-wide settings, installs no packages,
performs no network egress to untrusted hosts of sensitive data, does not
download-then-execute or write-then-execute code from untrusted sources, and
does not read secrets (keys, tokens, dotfiles outside the project).
Answer with SAFE or UNSAFE as the first line, then one short rationale line."
  "Fixed blast-radius policy preamble for the judge.")

(defun gptel-permit--judge-history (tool-call)
  "Return a history string of the last N buffer entries, or \"\".
N is `gptel-permit-judge-history-entries'.  Uses the buffer stored in the
tool call's :buffer (a buffer name string); each message is truncated."
  (if (and (> gptel-permit-judge-history-entries 0)
           (plist-get tool-call :buffer))
      (let ((buf (get-buffer (plist-get tool-call :buffer))))
        (if (buffer-live-p buf)
            (let ((entries (condition-case nil
                               (with-current-buffer buf
                                 (gptel--parse-buffer gptel-backend
                                                      gptel-permit-judge-history-entries))
                             (error nil))))
              (if entries
                  (mapconcat (lambda (e) (gptel-permit--truncate-arg (format "%S" e)))
                             entries "\n")
                ""))
          ""))
    ""))

(defun gptel-permit--judge-build-prompt (value tool-call)
  "Build the judge prompt string for VALUE of TOOL-CALL."
  (mapconcat
   #'identity
   (delq nil
         (list gptel-permit--judge-preamble
               (when (> (length gptel-permit-judge-policy) 0)
                 (concat "Additional policy:\n" gptel-permit-judge-policy))
               (let ((hist (gptel-permit--judge-history tool-call)))
                 (when (> (length hist) 0)
                   (concat "Recent context:\n" hist)))
               (format "TOOL CALL:\nTool: %s\nKey: %s\nValue:\n%s"
                       (plist-get tool-call :name)
                       (plist-get tool-call :checked-arg)
                       (gptel-permit--truncate-arg value))))
   "\n\n"))

(defun gptel-permit--judge-request-sync (prompt)
  "Send PROMPT to the judge backend and return the response string, or nil.
Blocks up to `gptel-permit-judge-timeout' seconds.  Any failure (unknown
backend name, request error, timeout, C-g) returns nil.  Errors are caught
explicitly (including `user-error' from `gptel-get-backend'); the explicit
(quit) handler plus `with-local-quit' in the body keep C-g interruptible."
  (let ((done nil)
        (resp nil))
    (catch 'judge-abort
      (condition-case err
          (with-local-quit
            (let ((gptel-backend (gptel-get-backend gptel-permit-judge-backend))
                  (gptel-model gptel-permit-judge-model)
                  (gptel-use-tools nil)
                  (gptel-use-context nil)
                  (gptel-stream nil))
              (gptel-request prompt
                :callback (lambda (response _info)
                            (setq resp (when (stringp response) response))
                            (setq done t)))
              (let ((deadline (time-add nil gptel-permit-judge-timeout)))
                (while (and (not done) (time-less-p nil deadline))
                  (accept-process-output nil 0.05)))))
        (quit (setq resp nil) (throw 'judge-abort nil))
        (error
         (gptel-permit--log "Judge request failed: %s" (error-message-string err))
         (setq resp nil))))
    resp))

(defun gptel-permit--judge-parse-verdict (response)
  "Parse RESPONSE into (VERDICT . RATIONALE), or nil if unparseable.
VERDICT is the symbol `safe' or `unsafe'.  RATIONALE is the remainder of the
response text (possibly empty).  Only an explicit first-line SAFE/UNSAFE
parses; anything else returns nil."
  (when (stringp response)
    (let ((lines (split-string (string-trim response) "\n")))
      (pcase (string-trim (upcase (car lines)))
        ("SAFE"   (cons 'safe   (string-trim (mapconcat #'identity (cdr lines) "\n"))))
        ("UNSAFE" (cons 'unsafe (string-trim (mapconcat #'identity (cdr lines) "\n"))))
        (_ nil)))))

(defun gptel-permit-judge-safe-p (value tool-call)
  "Return non-nil if the judge models VALUE of TOOL-CALL as obviously safe.
This is a deny-only condition: it never blocks, and every failure path
(unconfigured backend, request error, timeout, C-g, unparseable output,
UNSAFE verdict) returns nil so the enclosing rule does not match and
evaluation falls through to later rules.  On any evaluated verdict the
judge's rationale is stored in `gptel-permit--last-judge-rationale'."
  (setq gptel-permit--last-judge-rationale nil)
  (if (not gptel-permit-judge-backend)
      (progn
        (gptel-permit--log "Judge: disabled (gptel-permit-judge-backend is nil)")
        nil)
    (message "gptel-permit: judging %s call..." (plist-get tool-call :name))
    (let* ((prompt (gptel-permit--judge-build-prompt value tool-call))
           (response (gptel-permit--judge-request-sync prompt))
           (parsed (gptel-permit--judge-parse-verdict response))
           (verdict (car parsed))
           (rationale (or (cdr parsed) "")))
      (setq gptel-permit--last-judge-rationale rationale)
      (gptel-permit--log "Judge verdict: %s rationale: %s"
                         (or verdict "FAIL") gptel-permit--last-judge-rationale)
      (message nil)
      (eq verdict 'safe))))

(provide 'gptel-permit-judge)
;;; gptel-permit-judge.el ends here
