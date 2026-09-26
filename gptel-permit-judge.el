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
;;
;; Judge requests are isolated from the calling session: they carry no
;; system message, so the session's persona never reaches the judge
;; model, and leaked model reasoning cannot hide the verdict.

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

(defcustom gptel-permit-judge-request-params nil
  "Plist of extra request parameters for judge requests, or nil.
The effective plist is let-bound as gptel's `gptel--request-params'
around the judge request; gptel merges it into the request body with
precedence: gptel's request defaults < these params < the backend's
`:request-params' < the model's `:request-params'.  The effective
value is logged via `gptel-permit--log' on every judge request.

When nil (the default) and `gptel-permit-judge-control-thinking'
is non-nil, thinking-off parameters are derived from the
judge backend's type (see `gptel-permit--judge-thinking-off-params'):
Anthropic `(:thinking (:type \"disabled\"))', OpenAI
`(:reasoning_effort \"minimal\")', Gemini `(:generationConfig
(:thinkingConfig (:thinkingBudget 0)))', Ollama `(:think :json-false)'
— or `(:think \"low\")' when the judge model's base name is a GPT-OSS
model, which ignores booleans and cannot fully disable its trace;
unrecognized backends derive nil (no injection).  Note that an empty
plist is indistinguishable from nil in Emacs Lisp, so there is no
separate \"empty\" state: set this to a non-nil plist to override the
derived default, e.g. keep a thinking judge on Anthropic with
`(:thinking (:type \"enabled\" :budget_tokens 1024))'.

Caveat (Gemini): gptel's merge is shallow, so a `:generationConfig'
here replaces any `:generationConfig' gptel builds itself (temperature,
max tokens).  Judge requests are bare, so this clobbering is safe; do
not use this plist to carry unrelated generation settings.

Caveat (Ollama cloud models): `:cloud'-tagged Ollama models have been
observed to ignore the derived `:think :json-false' and interleave
their reasoning with the answer text.  Verdict parsing tolerates
leaked reasoning (see `gptel-permit--judge-parse-verdict'): the first
standalone SAFE/UNSAFE line divides the response — text above it is
dropped as reasoning, text below it is the rationale."
  :type '(choice (const :tag "Derive thinking-off params per backend" nil)
                 (plist :tag "Fixed plist of request parameters"
                        :key-type symbol :value-type sexp))
  :group 'gptel-permit-judge)

(defcustom gptel-permit-judge-control-thinking t
  "Whether to try to control the judge model's thinking behavior.
When non-nil (the default), thinking-suppression parameters are
derived per backend (see `gptel-permit--judge-thinking-off-params')
and merged into the judge request.  When nil, nothing is derived:
the judge request carries no thinking-related parameters at all, so
the model runs with its backend default.  Parameters you set
explicitly via `gptel-permit-judge-request-params' are always sent
verbatim, regardless of this switch.

Why nil: some models ignore these fields — one Ollama cloud model
(glm) has been observed to leak *more* reasoning into its answer
when a think parameter is sent than when the request says nothing
at all.  If your judge leaks reasoning or glues its verdict onto a
prose line, try nil; the parser tolerates leaked reasoning anyway
(see `gptel-permit--judge-parse-verdict')."
  :package-version '(gptel-permit . "0.4")
  :type 'boolean
  :group 'gptel-permit-judge)



(defvar-local gptel-permit--last-judge-rationale nil
  "Rationale from the most recent judge verdict in this buffer.
Set by `gptel-permit-judge-safe-p'; intended for audit/analytics.
For an evaluated verdict (`safe' or `unsafe') this is the judge's own
rationale — the response text below the divider verdict line, or
\"\" when the response carried none.  For the failure class
`parse-fail' this holds the full raw judge response, kept untruncated
to aid debugging (the response the judge produced but could not be
parsed); for `request-fail' and `timeout' it is nil — no response
arrived.")

(defvar-local gptel-permit--last-judge-verdict nil
  "Verdict symbol from the most recent judge run in this buffer.
One of `safe' or `unsafe' (an evaluated judge verdict), one of the
failure classes `parse-fail' (response arrived but its first line was
neither SAFE nor UNSAFE), `request-fail' (the request itself failed:
unknown backend name, HTTP error, no response) or `timeout'
(`gptel-permit-judge-timeout' elapsed, or the wait was interrupted
with C-g), or nil when no judge run occurred.  Set by
`gptel-permit-judge-safe-p'; reset per tool call by
`gptel-permit-judge--reset-state' on
`gptel-permit-before-rule-match-functions'; intended for audit/analytics.")


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
                       ;; (gptel-permit--truncate-arg value)
                       value
                       )))
   "\n\n"))

(defun gptel-permit--judge-ollama-think-params (model)
  "Return thinking-off request params for the Ollama MODEL name.
GPT-OSS models ignore boolean `think' and accept only levels, with the
trace unable to be fully disabled, so the smallest accepted level,
\"low\", is derived for them.  Every other model derives
`:json-false', which Ollama treats as a harmless no-op for models
without a thinking capability.  MODEL is matched on its base name
(before the first \":\")."
  (if (and (stringp model)
           (equal "gpt-oss" (car (split-string model ":"))))
      '(:think "low")
    '(:think :json-false)))

(defun gptel-permit--judge-thinking-off-params (backend &optional model)
  "Return a plist disabling model thinking for judge requests to BACKEND.
MODEL is the judge model name (see `gptel-permit-judge-model'); the
Ollama branch uses it — GPT-OSS models take a thinking level instead
of a boolean (see `gptel-permit--judge-ollama-think-params').
Matched on BACKEND's struct type via `type-of', so no backend library
needs to be loaded to classify it: Anthropic gets thinking disabled,
OpenAI (Completions) a minimal reasoning effort, Gemini a zero
thinking budget and Ollama thinking turned off (or minimized, for
GPT-OSS).  Any other backend type — including OpenAI Responses, whose
`reasoning' grammar differs — derives nil: nothing is injected and
the model's default applies."
  (pcase (type-of backend)
    ('gptel-anthropic '(:thinking (:type "disabled")))
    ('gptel-openai    '(:reasoning_effort "minimal"))
    ('gptel-gemini    '(:generationConfig
                        (:thinkingConfig (:thinkingBudget 0))))
    ('gptel-ollama    (gptel-permit--judge-ollama-think-params model))
    (_ nil)))


(defun gptel-permit--judge-request-sync (prompt)
  "Send PROMPT to the judge backend and return the outcome plist.
The plist carries `:class' — `ok' (the judge responded),
`request-fail' (the request signaled an error, or gptel reported a
failure with no response), `timeout' (`gptel-permit-judge-timeout'
elapsed) or `interrupted' (the user pressed C-g) — and `:response',
the response string when `:class' is `ok'.  Blocks up to
`gptel-permit-judge-timeout' seconds.  Every failure class logs its
own line via `gptel-permit--log': `Judge request failed: …',
`Judge timeout after Ns' or `Judge interrupted'.  Errors are caught
explicitly (including `user-error' from `gptel-get-backend'); the
explicit (quit) handler plus `with-local-quit' in the body keep C-g
interruptible.  The effective request parameters (see
`gptel-permit-judge-request-params') are let-bound as
`gptel--request-params' around the request and logged once;
thinking-off parameters are derived only while
`gptel-permit-judge-control-thinking' is non-nil.  The
request is issued with `:system nil': no system message is sent, so
the calling buffer's system prompt — persona or role directive —
never reaches the judge; the judge preamble is the only
role-setting text the model sees."
  (let ((done nil)
        (resp nil)
        (status nil))
    (catch 'judge-abort
      (condition-case err
          (with-local-quit
            (let* ((backend (gptel-get-backend gptel-permit-judge-backend))
                   (gptel--request-params
                    (or gptel-permit-judge-request-params
                        (when gptel-permit-judge-control-thinking
                          (gptel-permit--judge-thinking-off-params
                           backend gptel-permit-judge-model))))
                   (gptel-backend backend)
                   (gptel-model gptel-permit-judge-model)
                   (gptel-use-tools nil)
                   (gptel-use-context nil)
                   (gptel-stream nil))
              (gptel-permit--log "Judge request params: %S"
                                 gptel--request-params)
              (gptel-request prompt
                :system nil
                :callback (lambda (response info)
                            (setq resp (when (stringp response) response)
                                  status (plist-get info :status)
                                  done t)))
              (let ((deadline (time-add nil gptel-permit-judge-timeout)))
                (while (and (not done) (time-less-p nil deadline))
                  (accept-process-output nil 0.05)))))
        (quit (gptel-permit--log "Judge interrupted")
              (throw 'judge-abort (list :class 'interrupted :response nil)))
        (error
         (gptel-permit--log "Judge request failed: %s"
                            (error-message-string err))
         (throw 'judge-abort (list :class 'request-fail :response nil))))
      (cond
       ((and done (stringp resp)) (list :class 'ok :response resp))
       (done (gptel-permit--log "Judge request failed: %s"
                                (or status "no response"))
             (list :class 'request-fail :response nil))
       (t (gptel-permit--log "Judge timeout after %ss"
                             gptel-permit-judge-timeout)
          (list :class 'timeout :response nil))))))

(defconst gptel-permit--judge-think-close-re
  "</\\(?:[Tt][Hh][Ii][Nn][Kk][Ii][Nn][Gg]\\|[Tt][Hh][Ii][Nn][Kk]\\)>"
  "Regexp matching a closing reasoning tag emitted by some models.
Applied to the raw judge response before the divider rules: a
closing tag (glued onto a prose line or on its own) marks where
leaked reasoning ends and the answer starts.  Built from character
classes so this source file carries no literal tag bytes.")

(defun gptel-permit--judge-drop-thinking (response)
  "Return RESPONSE with leaked reasoning dropped, heuristically.
When a closing reasoning tag (see `gptel-permit--judge-think-close-re')
appears anywhere in RESPONSE, everything up to and including the
LAST one is treated as reasoning and dropped: the answer starts
after it.  Without a closing tag, RESPONSE is returned unchanged —
an unclosed reasoning block provides no trustworthy boundary, and
the divider rules of `gptel-permit--judge-parse-verdict' decide on
the full text."
  (or (car (last (split-string response
                                gptel-permit--judge-think-close-re t)))
      ""))

(defun gptel-permit--judge-parse-verdict (response)
  "Parse RESPONSE into (VERDICT . RATIONALE), or nil if unparseable.
VERDICT is the symbol `safe' or `unsafe'.  First the closing-tag
heuristic runs: when the response contains a closing reasoning tag,
everything up to and including the last one is dropped as reasoning
(see `gptel-permit--judge-drop-thinking').  Then the divider applies
to what remains: the first line whose trimmed, upcased text is
exactly SAFE or UNSAFE divides it — everything above is leaked
reasoning and is dropped; everything below is RATIONALE (possibly
empty; later standalone verdict words stay in it).  Verdict words
glued into longer lines do not count.  If no standalone SAFE/UNSAFE
line exists, or both words appear as standalone lines anywhere in
the remaining text (an exploratory draft disagreeing with the
conclusion), the response is unparseable: callers treat that as a
failed judgement, fail-closed."
  (when (stringp response)
    (let* ((answer (gptel-permit--judge-drop-thinking response))
           (lines (split-string answer "\n"))
           (hits (delq nil
                       (seq-map-indexed
                        (lambda (line idx)
                          (pcase (string-trim (upcase line))
                            ("SAFE"   (cons idx 'safe))
                            ("UNSAFE" (cons idx 'unsafe))
                            (_ nil)))
                        lines)))
           (values (delete-dups (mapcar #'cdr hits)))
           (divider (car hits)))
      (when (and divider (= (length values) 1))
        (cons (cdr divider)
              (string-trim
               (mapconcat #'identity
                          (nthcdr (1+ (car divider)) lines)
                          "\n")))))))

(defun gptel-permit--judge-evaluate (result)
  "Reduce judge request RESULT to a verdict and record it in this buffer.
RESULT is the outcome plist from `gptel-permit--judge-request-sync'.
Records the verdict in `gptel-permit--last-judge-verdict' and the
rationale (or the full raw response for `parse-fail', kept untruncated
to aid debugging) in `gptel-permit--last-judge-rationale' — see their
docstrings — logs the evaluated verdict, and returns the verdict
symbol: `safe' or `unsafe'
when the response parsed, or a failure class (`parse-fail',
`request-fail', `timeout').  A C-g interruption is recorded as
`timeout'; every failure keeps the condition deny-only."
  (let* ((class (plist-get result :class))
         (response (plist-get result :response))
         (parsed (when (eq class 'ok)
                   (gptel-permit--judge-parse-verdict response)))
         (verdict (or (car parsed)
                      (pcase class
                        ('ok 'parse-fail)
                        ('timeout 'timeout)
                        ('interrupted 'timeout)
                        (_ 'request-fail)))))
    (setq gptel-permit--last-judge-verdict verdict
          gptel-permit--last-judge-rationale
          (pcase verdict
            ((or 'safe 'unsafe) (or (cdr parsed) ""))
            ('parse-fail (or response ""))
            (_ nil)))
    (if parsed
        (gptel-permit--log "Judge verdict: %s rationale: %s"
                           verdict gptel-permit--last-judge-rationale)
      (when (eq verdict 'parse-fail)
        (gptel-permit--log "Judge response unparseable: %s"
                           gptel-permit--last-judge-rationale)))
    verdict))


(defun gptel-permit-judge-safe-p (value tool-call)
  "Return non-nil if the judge models VALUE of TOOL-CALL as obviously safe.
This is a deny-only condition: it never blocks, and every failure path
(unconfigured backend, request error, timeout, C-g, unparseable output,
UNSAFE verdict) returns nil so the enclosing rule does not match and
evaluation falls through to later rules.  Every judge run records its
outcome in `gptel-permit--last-judge-verdict' — `safe', `unsafe' or a
failure class — and the rationale or raw response in
`gptel-permit--last-judge-rationale'; both are nil when the judge is
disabled or has not run."
  (setq gptel-permit--last-judge-rationale nil
        gptel-permit--last-judge-verdict nil)
  (if (not gptel-permit-judge-backend)
      (progn
        (gptel-permit--log "Judge: disabled (gptel-permit-judge-backend is nil)")
        nil)
    (message "gptel-permit: judging %s call..." (plist-get tool-call :name))
    (let ((verdict (gptel-permit--judge-evaluate
                    (gptel-permit--judge-request-sync
                     (gptel-permit--judge-build-prompt value tool-call)))))
      (message nil)
      (eq verdict 'safe))))

(defun gptel-permit-judge--reset-state (_id _tool-call)
  "Clear the judge's per-call verdict state in this buffer.
_ID and _TOOL-CALL are the call's tool-call id and the enriched tool call;
both are ignored.  Runs once per processed tool call, before rule
matching, on `gptel-permit-before-rule-match-functions', so state set by
a judged call can never leak into a later, unjudged call's analytics
events."
  (setq gptel-permit--last-judge-rationale nil
        gptel-permit--last-judge-verdict nil))

;; Self-registration at load time: the core owns no judge symbols.  The
;; named function makes repeated loads idempotent.
(add-hook 'gptel-permit-before-rule-match-functions
          #'gptel-permit-judge--reset-state)


(provide 'gptel-permit-judge)
;;; gptel-permit-judge.el ends here
