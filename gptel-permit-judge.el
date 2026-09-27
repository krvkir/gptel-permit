;;; gptel-permit-judge.el --- LLM-as-a-judge condition for gptel-permit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 krvkir

;; Author: krvkir <krvkir@gmail.com>
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.0.1"))
;; Keywords: convenience, tools, agents, security
;; URL: https://github.com/krvkir/gptel-permit

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; An LLM-as-a-judge for gptel-permit rules, in two forms.  The judge
;; asks a small local model whether a grey-zone tool call (e.g. a Bash
;; command) has a blast radius confined to the project and is safe to
;; auto-allow.
;;
;; The condition form (`gptel-permit-judge-safe-p') is deny-only: it
;; returns a boolean for use as a :conditions value and never produces a
;; :block verdict.  All failure paths return nil, so the enclosing rule
;; does not match and evaluation falls through to the next rule
;; (normally ask).
;;
;; The action form (`judge', `(judge A)', `(judge ON-SAFE ON-UNSAFE)')
;; owns the matched call: the judge's verdict picks the resolution —
;; SAFE applies ON-SAFE, UNSAFE applies ON-UNSAFE, and any failure
;; resolves to manual confirmation.  See `gptel-permit--action-judge'
;; and `gptel-permit-judge-async'.
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

(defcustom gptel-permit-judge-async t
  "When non-nil (the default), judge actions resolve asynchronously.
The hook returns a manual-confirmation prompt immediately, the judge
request runs in the background, and the verdict is applied by a
callback: a uniform SAFE pack is auto-accepted, UNSAFE applies the
rule's UNSAFE action, and any failure leaves the prompt.  The
confirmation prompt stays visible while judging — the accepted
tradeoff for never freezing Emacs.  When nil, judge actions block
like the judge condition (`gptel-permit-judge-safe-p') does, for up
to `gptel-permit-judge-timeout' seconds per call."
  :package-version '(gptel-permit . "0.5")
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

(defun gptel-permit--judge-format-args (tool-call)
  "Return the full argument set of TOOL-CALL as a judge-readable string.
Used by the judge action: unlike the judge condition, which judges one
condition-selected value, the action judges every argument."
  (mapconcat
   (lambda (pair) (format "%s %s" (car pair) (cdr pair)))
   (cl-loop for (k v) on (plist-get tool-call :args) by #'cddr
            collect (cons k v))
   "\n"))

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
               (if-let* ((checked (plist-get tool-call :checked-arg)))
                   (format "TOOL CALL:\nTool: %s\nKey: %s\nValue:\n%s"
                           (plist-get tool-call :name)
                           checked
                           ;; (gptel-permit--truncate-arg value)
                           value)
                 (format "TOOL CALL:\nTool: %s\nArgs:\n%s"
                         (plist-get tool-call :name)
                         value))))
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


(defun gptel-permit--judge-request-body (prompt callback)
  "Issue the judge request for PROMPT with gptel CALLBACK.
Shared by the sync and async request modes: resolves the judge
backend, derives or applies the effective request parameters (see
`gptel-permit-judge-request-params'), binds the isolation variables
(no tools, no context, no streaming, the judge model), and issues the
request with `:system nil' so the calling buffer's system prompt never
reaches the judge."
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
    (gptel-permit--log "Judge request params: %S" gptel--request-params)
    (gptel-request prompt :system nil :callback callback)))

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
interruptible.  The request itself is issued by
`gptel-permit--judge-request-body', which see for the request
parameters, isolation bindings and `:system nil' rationale."
  (let ((done nil)
        (resp nil)
        (status nil))
    (catch 'judge-abort
      (condition-case err
          (with-local-quit
            (gptel-permit--judge-request-body
             prompt
             (lambda (response info)
               ;; gptel may fire the callback several times: a
               ;; (reasoning . TEXT) cons carries leaked reasoning and is
               ;; followed by the real answer, nil/t are terminal.  Only
               ;; terminal deliveries end the wait; a string is the
               ;; answer itself.
               (when (gptel-permit--judge-final-response-p response)
                 (setq resp (and (stringp response) response)
                       status (plist-get info :status)
                       done t))))
            (let ((deadline (time-add nil gptel-permit-judge-timeout)))
              (while (and (not done) (time-less-p nil deadline))
                (accept-process-output nil 0.05))))
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

;;; Judge action — async resolution machinery

(defconst gptel-permit--judge-action-symbols '(allow deny ask sandbox)
  "Action symbols valid in the ON-SAFE and ON-UNSAFE slots of a judge action.")

(defvar-local gptel-permit--judge-pending nil
  "Alist of in-flight asynchronous judge calls in this buffer.
Keys are (TOOL-NAME . ARGS) conses (ARGS compared with `equal');
entries are plists:
  :id          the tool-call id minted by the rule engine,
  :tool-call   the enriched tool call,
  :actions     the (ON-SAFE . ON-UNSAFE) pair,
  :timer       the watchdog timer,
  :indicator   non-nil once the judging indicator was attached,
  :issued-at   the issue time (float, for the judge-verdict latency),
  :resolved    nil (in flight), t (timed out), or the verdict symbol
               once the judge answered.")

(defun gptel-permit--judge-normalize-actions (form)
  "Normalize a judge action FORM to (ON-SAFE . ON-UNSAFE), or nil if malformed.
FORM is nil (bare `judge') or the cdr of a judge list.  Bare `judge'
defaults to (allow . ask); (judge A) defaults ON-UNSAFE to `ask'.
Malformed forms — wrong arity or symbols outside
`gptel-permit--judge-action-symbols' — log a warning and return nil,
which the action handler resolves as `ask'."
  (pcase form
    ('nil '(allow . ask))
    ((and `(,a) (guard (memq a gptel-permit--judge-action-symbols)))
     (cons a 'ask))
    ((and `(,a ,b)
          (guard (and (memq a gptel-permit--judge-action-symbols)
                      (memq b gptel-permit--judge-action-symbols))))
     (cons a b))
    (_ (gptel-permit--log "Judge action: malformed form %S — behaving as ask" form)
       nil)))

(defun gptel-permit--judge-verdict-glyph (resolved)
  "Return the (GLYPH . FACE) pair for a stash entry's RESOLVED state.
nil is still waiting; t is a watchdog timeout; `safe' and `unsafe'
are real verdicts; any other symbol is a failed judgement."
  (pcase resolved
    ('nil '("⏳" . default))
    ('t '("⚠" . warning))
    ('safe '("✅" . success))
    ('unsafe '("⛔" . error))
    (_ '("⚠" . warning))))

(defun gptel-permit--judge-overlay-entries (ov)
  "Return the judge-gated stash entries whose pack overlay is OV.
Each element is a (KEY . ENTRY) cons from this buffer's pending
alist whose (TOOL-NAME . ARGS) key currently pends on OV's
`gptel-tool' triples; entries whose overlay is gone — the user
answered that pack — are skipped."
  (cl-loop for (key . entry) in gptel-permit--judge-pending
           when (eq (gptel-permit--judge-find-pending-overlay key) ov)
           collect (cons key entry)))

(defun gptel-permit--judge-status-line (entries)
  "Build the judging status string from a pack's pending ENTRIES.
Every judge-gated call shows as NAME GLYPH; when all of them are
judged but the pack still awaits a manual decision, the line says
so."
  (let* ((glyphs (mapcar (pcase-lambda (`(,_ . ,entry))
                           (pcase-let ((`(,glyph . ,face)
                                        (gptel-permit--judge-verdict-glyph
                                         (plist-get entry :resolved))))
                             (propertize
                              (format "%s %s"
                                      (plist-get (plist-get entry :tool-call)
                                                 :name)
                                      glyph)
                              'face face)))
                         entries))
         (all-judged (cl-every (pcase-lambda (`(,_ . ,entry))
                                (plist-get entry :resolved))
                              entries)))
    (concat (propertize "judging: " 'face 'font-lock-doc-face)
            (mapconcat #'identity glyphs " · ")
            (when (and entries all-judged)
              (propertize " — manual confirm required"
                          'face 'font-lock-doc-face)))))

(defun gptel-permit--judge-action-verdict (id tool-call verdict on-safe on-unsafe)
  "Map judge VERDICT to a resolution verdict plist for TOOL-CALL.
ID is the tool-call id.  `safe' resolves through the ON-SAFE action,
`unsafe' through ON-UNSAFE, each dispatched through
`gptel-permit-action-handlers' with the same ID and TOOL-CALL — a
`deny' resolution embeds the judge rationale in its block reason.  A
failure class (`parse-fail', `request-fail', `timeout') resolves to
`(:confirm t)': the human decides what the judge could not.  An
unregistered or nil-returning action handler resolves to
`(:confirm t)' as well (fail closed)."
  (pcase verdict
    ((or 'safe 'unsafe)
     (let* ((sym (if (eq verdict 'safe) on-safe on-unsafe)))
       (if (eq sym 'deny)
           (list :block (format "Judge rejected: %s"
                                gptel-permit--last-judge-rationale))
         (let ((handler (cdr (assq sym gptel-permit-action-handlers))))
           (if handler
               (or (funcall handler id tool-call)
                   (list :confirm t))
             (gptel-permit--log
              "Judge action: no handler for %S — failing closed" sym)
             (list :confirm t))))))
    (_ (list :confirm t))))

(defun gptel-permit--judge-request-async (prompt callback)
  "Send PROMPT to the judge backend without blocking; CALLBACK receives (RESPONSE INFO).
The request shares `gptel-permit--judge-request-body' with the
synchronous mode; errors issuing the request are caught and CALLBACK
is invoked with a nil response, which the resolution path records as
`request-fail'.  Returns non-nil if the request was issued."
  (condition-case err
      (progn (gptel-permit--judge-request-body prompt callback)
             t)
    (error
     (gptel-permit--log "Judge request failed: %s" (error-message-string err))
     (funcall callback nil nil)
     nil)))

(defun gptel-permit--judge-refresh-indicator (ov)
  "Create or update the judging status indicator for OV's pack.
The status line (see `gptel-permit--judge-status-line') is rebuilt
from this buffer's pending entries that still pend on OV, so every
verdict or timeout shows up in place.  With no judge-gated entries
left, any existing indicator is deleted instead.  The zero-width
indicator is stacked at the pack's first live prompt overlay's
start — gptel-owned text is never modified — and registered once as
a preview teardown handle, so gptel's own accept / steer / reject
cleanup removes it.  Returns the indicator overlay or nil."
  (let ((entries (gptel-permit--judge-overlay-entries ov)))
    (if (null entries)
        (gptel-permit--judge-drop-indicator ov)
      (when-let* ((prompt-ov (seq-find #'overlay-buffer
                                       (overlay-get ov 'prompt))))
        (let ((ind (cl-find-if #'overlayp
                               (overlay-get ov 'gptel-permit-judge-indicators))))
          (unless ind
            (setq ind (make-overlay (overlay-start prompt-ov)
                                    (overlay-start prompt-ov)))
            (overlay-put ind 'gptel-permit-judge-indicator t)
            (overlay-put ov 'gptel-permit-judge-indicators
                         (nconc (overlay-get ov 'gptel-permit-judge-indicators)
                                (list ind)))
            (overlay-put ov 'previews
                         (nconc (overlay-get ov 'previews)
                                (list (list
                                       #'gptel-permit--judge-teardown-indicator
                                       ind)))))
          (overlay-put ind 'before-string
                       (gptel-permit--judge-status-line entries))
          ind)))))

(defun gptel-permit--judge-teardown-indicator (ind)
  "Delete the judging indicator overlay IND.
Runs as a gptel preview teardown handle: gptel applies the car of
each handle to its cdr on accept, steer and reject."
  (when (overlayp ind)
    (delete-overlay ind)))

(defun gptel-permit--judge-drop-indicator (ov)
  "Delete the judging status indicators of OV's pack, if any.
Runs after the pack was programmatically accepted or rejected; the
user's own accept / steer / reject paths delete them through the
preview teardown handles instead."
  (dolist (ind (overlay-get ov 'gptel-permit-judge-indicators))
    (when (overlayp ind)
      (delete-overlay ind)))
  (overlay-put ov 'gptel-permit-judge-indicators nil))

(defun gptel-permit--judge-stash (id tool-call actions)
  "Stash an in-flight async judge call in this buffer and return its entry.
ID, TOOL-CALL and ACTIONS (the (ON-SAFE . ON-UNSAFE) pair) are stored
under the call's (NAME . ARGS) identity; a watchdog armed at
`gptel-permit-judge-timeout' resolves the call as a `timeout' failure,
and the judging status indicator is attached once the event loop
yields (the prompt overlay is created only after the hook returns)."
  (let* ((key (cons (plist-get tool-call :name) (plist-get tool-call :args)))
         (entry (list :id id :tool-call tool-call :actions actions
                      :timer nil :indicator nil :resolved nil
                      :issued-at (float-time)))
         (buffer (current-buffer)))
    (plist-put entry :timer
               (run-at-time gptel-permit-judge-timeout nil
                            #'gptel-permit--judge-watchdog buffer key))
    (push (cons key entry) gptel-permit--judge-pending)
    (run-at-time 0 nil
                 (lambda (buf k)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (let ((e (cdr (assoc k gptel-permit--judge-pending
                                            (lambda (a b) (equal a b))))))
                         (when (and e
                                    (null (plist-get e :resolved))
                                    (gptel-permit--judge-find-pending-overlay k))
                           (plist-put e :indicator
                                      (gptel-permit--judge-refresh-indicator
                                       (gptel-permit--judge-find-pending-overlay
                                        k))))))))
                 buffer key)
    entry))

(defun gptel-permit--judge-watchdog (buffer key)
  "Resolve the async judge call KEY in BUFFER as a timeout.
Runs at `gptel-permit-judge-timeout' after issue; an already-resolved
entry is left alone.  The call stays on its manual prompt, the pack's
status indicator now shows the timeout glyph, and the failure is
logged; a late verdict hitting the entry is discarded as already
resolved."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((entry (cdr (assoc key gptel-permit--judge-pending
                               (lambda (a b) (equal a b))))))
        (when (and entry (null (plist-get entry :resolved)))
          (plist-put entry :resolved t)
          (setq gptel-permit--last-judge-verdict 'timeout
                gptel-permit--last-judge-rationale nil)
          (gptel-permit--log "Judge timeout after %ss"
                             gptel-permit-judge-timeout)
          (when-let* ((ov (gptel-permit--judge-find-pending-overlay key)))
            (gptel-permit--judge-refresh-indicator ov)))))))

(defun gptel-permit--judge-triple-tool-name (triple)
  "Return the tool name of a pending-call TRIPLE, or nil.
The car is normally a gptel tool struct; failing that, a symbol's name
is used, so a triple that matches no stashed identity simply never
resolves programmatically (fail closed)."
  (let ((spec (car triple)))
    (cond ((and (fboundp 'gptel-tool-p) (gptel-tool-p spec))
           (gptel-tool-name spec))
          ((symbolp spec) (symbol-name spec))
          (t nil))))

(defun gptel-permit--judge-find-pending-overlay (key)
  "Return the tool overlay in this buffer whose pack contains KEY.
KEY is a (TOOL-NAME . ARGS) cons; a triple matches when its tool
spec's name is the car and its args are `equal' to the cdr."
  (cl-find-if
   (lambda (ov)
     (cl-some (lambda (triple)
                (and (consp triple)
                     (equal (gptel-permit--judge-triple-tool-name triple)
                            (car key))
                     (equal (cadr triple) (cdr key))))
              (overlay-get ov 'gptel-tool)))
   (overlays-in (point-min) (point-max))))

(defun gptel-permit--judge-emit-verdict-event (id tool-call verdict latency-ms)
  "Emit the judge-verdict event for ID and TOOL-CALL through the core.
VERDICT is the verdict symbol (including failure classes); the payload
carries the rationale, the judged argument string, and LATENCY-MS (nil
in sync mode).  Emitted from the verdict-owning buffer so the per-call
judge state is current for observers."
  (gptel-permit--emit-event
   id tool-call :judge-verdict
   (list :verdict verdict
         :rationale gptel-permit--last-judge-rationale
         :arg (gptel-permit--judge-format-args tool-call)
         :latency-ms latency-ms)))

(defun gptel-permit--judge-final-response-p (response)
  "Return non-nil if RESPONSE is a terminal gptel callback delivery.
gptel may call its callback several times per request: a cons
\(reasoning . TEXT) carries leaked reasoning and is followed by the
real answer; a string is the answer itself; nil is a terminal failure;
t means an empty body with a success status.  Everything else is
intermediate and ignored."
  (or (stringp response) (null response) (eq response t)))

(defun gptel-permit--judge-resolve-callback (buffer key response info)
  "Deliver the async judge RESPONSE for KEY in BUFFER to its resolution.
The gptel callback for an async judge request: parses the verdict in
the verdict-owning buffer (so the per-call judge state vars are set
where analytics reads them), computes the resolution verdict, consults
`gptel-permit-veto-functions' with it (a veto — e.g. audit sampling —
forces the manual resolution), records both on the stash entry, and
attempts the pack resolution.  Intermediate deliveries — gptel may
fire its callback several times, e.g. with a (reasoning . TEXT) cons
before the final string — are ignored while the wait continues.  A
failed request arrives as nil, an empty success as t; both record
`request-fail'.  Guards make every stale delivery a no-op: dead
buffer, missing or already-resolved entry (watchdog fired or user
acted first)."
  (when (and (buffer-live-p buffer)
             (gptel-permit--judge-final-response-p response))
    (with-current-buffer buffer
      (let ((entry (cdr (assoc key gptel-permit--judge-pending
                               (lambda (a b) (equal a b))))))
        (cond
         ((or (null entry) (plist-get entry :resolved))
          (gptel-permit--log "Judge: discarded late verdict for %S" key))
         ;; No prompt left: the user answered first (or answered the
         ;; minibuffer prompt — there never was an overlay).  Their
         ;; decision stands; the stale verdict is discarded.
         ((null (gptel-permit--judge-find-pending-overlay key))
          (plist-put entry :resolved t)
          (when-let* ((timer (plist-get entry :timer)))
            (cancel-timer timer))
          (gptel-permit--log "Judge: user acted first — discarded verdict for %S"
                             key))
         (t
          (when-let* ((timer (plist-get entry :timer)))
            (cancel-timer timer))
          (let ((verdict (gptel-permit--judge-evaluate
                          (if (stringp response)
                              (list :class 'ok :response response)
                            ;; t (empty success body) and nil (failure):
                            ;; both are a failed judgement.
                            (gptel-permit--log "Judge request failed: %s"
                                               (or (plist-get info :status)
                                                   "no response"))
                            (list :class 'request-fail :response nil)))))
            (plist-put entry :resolved verdict)
            (gptel-permit--judge-emit-verdict-event
             (plist-get entry :id)
             (plist-get entry :tool-call)
             verdict
             (round (* 1000 (- (float-time)
                               (or (plist-get entry :issued-at)
                                   (float-time))))))
            (let ((verd (gptel-permit--judge-action-verdict
                         (plist-get entry :id)
                         (plist-get entry :tool-call)
                         verdict
                         (car (plist-get entry :actions))
                         (cdr (plist-get entry :actions)))))
              (when (and (plist-member verd :confirm)
                         (run-hook-with-args-until-success
                          'gptel-permit-veto-functions
                          (plist-get entry :id)
                          (plist-get entry :tool-call)
                          verd))
                (setq verd (if (plist-get verd :args)
                               (list :confirm t :args (plist-get verd :args))
                             (list :confirm t))))
              (plist-put entry :resolution verd)
              (gptel-permit--judge-resolve-pack key)))))))))

(defun gptel-permit--judge-pack-resolution (triples)
  "Return the uniform pack resolution for TRIPLES, or nil when not uniform.
TRIPLES are the overlay's pending tool calls.  The result is
`(:accept REWRITTEN-TRIPLES)' when every triple is judge-gated with an
accept-class resolution (`:confirm nil', with an `:args' rewrite
replacing the triple's args), `(:deny REASONS)' when every triple is
judge-gated with a `:block' resolution, and nil otherwise — missing or
unresolved entries, failure verdicts, `(:confirm t)' resolutions and
mixed packs never resolve programmatically."
  (let ((resolutions
         (mapcar (lambda (triple)
                   (let* ((name (gptel-permit--judge-triple-tool-name triple))
                          (key (and name (cons name (cadr triple))))
                          (entry (and key
                                      (cdr (assoc key gptel-permit--judge-pending
                                                  (lambda (a b) (equal a b)))))))
                     (when (and entry
                                (plist-get entry :resolved)
                                (not (eq (plist-get entry :resolved) t)))
                       (list :triple triple
                             :resolution (plist-get entry :resolution)))))
                 triples)))
    (cond
     ((or (null resolutions) (memq nil resolutions)) nil)
     ((cl-every (lambda (r)
                  (let ((verd (plist-get r :resolution)))
                    (and (consp verd)
                         (plist-member verd :confirm)
                         (null (plist-get verd :confirm)))))
                resolutions)
      (list :accept
            (cl-mapcar (lambda (r)
                         (pcase-let ((`(,spec ,args ,cb) (plist-get r :triple)))
                           (list spec
                                 (or (plist-get (plist-get r :resolution) :args)
                                     args)
                                 cb)))
                       resolutions)))
     ((cl-every (lambda (r)
                  (stringp (plist-get (plist-get r :resolution) :block)))
                resolutions)
      (list :deny
            (mapcar (lambda (r) (plist-get (plist-get r :resolution) :block))
                    resolutions)))
     (t nil))))

(defun gptel-permit--judge-resolve-pack (key)
  "Attempt the programmatic resolution of the pack containing KEY.
Resolves only a fully judge-gated, uniform pack (see
`gptel-permit--judge-pack-resolution'): all accept-class → rewritten
triples passed to `gptel--accept-tool-calls'; all deny → each pending
triple's callback fed the judge-rationale reason, then overlay
cleanup.  Both run under a `gptel-permit--programmatic-call' binding
so decision-capture advice can tell them apart from interactive
approvals.  Anything else leaves the prompt: the pack's status
indicator is refreshed in place (every judged call shows its glyph)
and the user is told why no auto-action happened."
  (let* ((ov (gptel-permit--judge-find-pending-overlay key))
         (resolution (and ov (overlay-buffer ov)
                          (gptel-permit--judge-pack-resolution
                           (overlay-get ov 'gptel-tool)))))
    (pcase resolution
      (`(:accept ,triples)
       (gptel-permit--judge-drop-indicator ov)
       (gptel-permit--judge-record-decision "auto-allow"
                                            (overlay-get ov 'gptel-tool) ov)
       (message "gptel-permit: judge SAFE — accepted %d tool call%s"
                (length triples) (if (cdr triples) "s" ""))
       (let ((gptel-permit--programmatic-call t))
         (when (fboundp 'gptel--accept-tool-calls)
           (gptel--accept-tool-calls triples ov))))
      (`(:deny ,reasons)
       (gptel-permit--judge-drop-indicator ov)
       (gptel-permit--judge-record-decision "deny"
                                            (overlay-get ov 'gptel-tool) ov)
       (message "gptel-permit: judge UNSAFE — rejected: %s"
                (car reasons))
       (let ((gptel-permit--programmatic-call t))
         (gptel-permit--judge-reject-pending
          (overlay-get ov 'gptel-tool) ov reasons)))
      (_
       (when ov
         (gptel-permit--judge-refresh-indicator ov)
         (let* ((entries (gptel-permit--judge-overlay-entries ov))
                (unresolved (cl-count-if (pcase-lambda (`(,_ . ,e))
                                           (null (plist-get e :resolved)))
                                         entries))
                (just (cdr (assoc key gptel-permit--judge-pending
                                  (lambda (a b) (equal a b))))))
           (gptel-permit--log
            "Judge: no programmatic resolution — %d unresolved of %d judge-gated"
            unresolved (length entries))
           (when just
             (message "gptel-permit: judge verdict for %s: %s — %s"
                      (plist-get (plist-get just :tool-call) :name)
                      (upcase (symbol-name (plist-get just :resolved)))
                      (if (zerop unresolved)
                          "pack mixes judged calls; confirm manually"
                        "pack not fully judged; confirm manually")))))))))

(defun gptel-permit--judge-record-decision (choice tool-calls ov)
  "Record programmatic CHOICE decisions for the pack's TOOL-CALLS on OV.
Pending confirmations are popped with the pre-rewrite args each
triple carries, so wait times correlate with the original confirm
event.  The actual event emission happens in the analytics module:
its `gptel-permit-analytics--record-decision' is only ever called
when that module is loaded — the judge module holds no analytics
knowledge beyond that public entry point."
  (when (fboundp 'gptel-permit-analytics--record-decision)
    (gptel-permit-analytics--record-decision choice tool-calls ov)))

(defun gptel-permit--judge-reject-pending (tool-calls ov reasons)
  "Reject the pending TOOL-CALLS on OV, feeding REASONS to the model.
Each triple's process-tool-result callback receives its reason (the
judge-rationale block string), so the conversation continues with the
rejection explained; the overlay and its prompts are then cleaned up
the way `gptel--steer-tool-calls' does (whose `read-string' is why it
cannot be reused directly)."
  (cl-loop for (_spec _args process-tool-result) in tool-calls
           for reason in reasons
           do (funcall process-tool-result reason))
  (when (and (overlayp ov) (overlay-buffer ov))
    (with-current-buffer (overlay-buffer ov)
      (when-let* ((preview-handles (overlay-get ov 'previews)))
        (dolist (func-to-handle preview-handles)
          (when (car func-to-handle) (apply func-to-handle))))
      (dolist (prompt-ov (overlay-get ov 'prompt))
        (when (overlay-buffer prompt-ov)
          (let ((inhibit-read-only t))
            (delete-region (overlay-start prompt-ov)
                           (overlay-end prompt-ov))))))
    (delete-overlay ov)))

(defun gptel-permit--action-judge (id tool-call &optional form)
  "Judge action handler: resolve the call by the judge's verdict.
FORM is nil (bare `judge') or the action's cdr ((A) or (A B)); see
`gptel-permit--judge-normalize-actions'.  The judge sees the call's
full argument set (`gptel-permit--judge-format-args').  Async mode
(the default, see `gptel-permit-judge-async') stashes the call, fires
the request and returns `(:confirm t)' — the callback applies the
resolution.  Sync mode blocks on the request and applies the shared
mapping inline.  A disabled judge or a malformed form fails closed
with `(:confirm t)'."
  (let ((actions (gptel-permit--judge-normalize-actions form)))
    (cond
     ((or (null gptel-permit-judge-backend) (null actions))
      (when (null gptel-permit-judge-backend)
        (gptel-permit--log "Judge: disabled (gptel-permit-judge-backend is nil)"))
      (list :confirm t))
     (gptel-permit-judge-async
      (let ((key (cons (plist-get tool-call :name)
                       (plist-get tool-call :args)))
            (buffer (current-buffer)))
        (gptel-permit--judge-stash id tool-call actions)
        (gptel-permit--judge-request-async
         (gptel-permit--judge-build-prompt
          (gptel-permit--judge-format-args tool-call) tool-call)
         (lambda (response info)
           (gptel-permit--judge-resolve-callback buffer key response info)))
        (list :confirm t)))
     (t
      (message "gptel-permit: judging %s call..." (plist-get tool-call :name))
      (let* ((verdict (gptel-permit--judge-evaluate
                       (gptel-permit--judge-request-sync
                        (gptel-permit--judge-build-prompt
                         (gptel-permit--judge-format-args tool-call)
                         tool-call)))))
        (gptel-permit--judge-emit-verdict-event id tool-call verdict nil)
        (let ((verd (gptel-permit--judge-action-verdict
                     id tool-call verdict (car actions) (cdr actions))))
          (message nil)
          verd))))))





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
;; named function and `add-to-list' make repeated loads idempotent.
(add-hook 'gptel-permit-before-rule-match-functions
          #'gptel-permit-judge--reset-state)

(add-to-list 'gptel-permit-action-handlers
             '(judge . gptel-permit--action-judge))


(provide 'gptel-permit-judge)
;;; gptel-permit-judge.el ends here
