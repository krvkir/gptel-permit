# Design: decoupling

## Context

`gptel-permit.el` today knows three optional modules by name:

- **Actions**: a `pcase` in `gptel-permit--apply-rules` (gptel-permit.el:486)
  hardcodes `allow`/`deny`/`ask`/`sandbox`; the `sandbox` branch goes through
  `gptel-permit--sandbox-dispatch` (fboundp-guarded, fail-closed when the
  module is absent) plus two `declare-function`s. Conditions are already
  extensible (`gptel-permit--condition-predicates`); actions are not.
- **Judge**: the core declares the judge's state vars (bare `defvar`s) and
  owns `gptel-permit--reset-judge-state`, called each call so a stale
  judgement cannot leak into the next call's analytics verdict event.
- **Analytics**: correlation ids are minted by the *analytics* module
  (`--next-id`, an integer serial seeded by scanning the log file for its
  maximum id) and returned to the core via a `:tool-call` notification; the
  core calls `--analytics-notify` four times per call and `--analytics-sample`
  once, both `fboundp` shims. Audit sampling duplicates the verdict-upgrade
  logic (rebuilding `(:confirm t :args …)`) inside analytics.

Facts this design leans on: gptel's hook protocol plists; `run-hook-with-args`
and `run-hook-with-args-until-success` as the standard abnormal-hook runners;
`gptel-permit--match-rule-p (rule tool-call)` already returns the matched
rule's action or nil; `gptel-permit--sandbox-action` already has exactly the
handler shape needed; analytics' runtime gate `--automation-allow-p` is
verdict-shaped (no hardcoded action names), while the stats-side
`--auto-allowed-p` hardcodes `("allow" "sandbox")`.

Related pending proposals: `sandbox-backend-registry` (a *different*
registry: sandbox tool adapters rewrite args; backend classes wrap commands —
do not conflate with the action registry here) and `judge-async-action`
(currently plans "the core recognizes judge forms in the action slot"; after
this change it registers a handler instead — see tasks).

## Goals / Non-Goals

**Goals:**
- The core runs and stays meaningful with zero optional modules: rules,
  validation, logging, fail-closed error handling — all core-owned.
- Every add-on integrates by registering into a documented core extension
  point, never by the core naming it.
- Preserve every current fail-closed guarantee, or make it strictly stronger.
- Keep the analytics JSONL vocabulary and per-chain event order unchanged;
  old log files stay aggregable.

**Non-Goals:**
- Rule syntax or first-match-wins semantics.
- The gptel-facing surface (`gptel-pre-tool-call-functions` registration,
  `C-c C-b`, gptel-internal advice).
- Re-keying pending confirmations on ids (still `(buffer tool args)`;
  future cleanup, see Open Questions).
- A public unload/unregister mechanism for the sandbox and judge modules
  (analytics keeps its existing register/unregister pair).

## Decisions

1. **Action registry: public alist of functions, keyed dispatch.**
   `gptel-permit-action-handlers`: SYMBOL → function. A rule names exactly
   one action, so keyed lookup is the correct shape — a hook chain
   ("first non-nil verdict wins") would make conflicting actions
   order-dependent. Mirrors the condition-predicate precedent. The old
   `fboundp` shim disappears because "module not loaded" *is* "action not
   registered", and unregistered actions fail closed (decision 2).

2. **Unknown/typo'd actions fail closed.**
   Matched rule, no handler → log + `(:confirm t)`. Today the pcase
   `_ → nil` defers, which can *auto-run* a tool whose `:confirm` slot is
   nil — the registry makes this strictly safer, at the cost of a behavior
   change for nonexistent actions (documented in the proposal as BREAKING).

3. **Uniform callback contract: every engine callback starts with
   `(ID TOOL-CALL)`.**
   Action handlers: `(ID TOOL-CALL)` → verdict plist | nil.
   `gptel-permit-before-rule-match-functions`: `(ID TOOL-CALL)`.
   `gptel-permit-events-functions`: `(ID TOOL-CALL TYPE PAYLOAD)`.
   `gptel-permit-veto-functions`: `(ID TOOL-CALL VERDICT)`.
   Alternative considered: `(TOOL-CALL …)` with the id only where needed —
   rejected; one contract sentence for the whole engine, and the pending
   judge-async handler needs the id to correlate its verdict events.
   Built-in handlers ignore the id.

4. **Core-minted string ids: `TIMESTAMP.PID.SERIAL`.**
   `gptel-permit--mint-id` returns e.g. `"20261005T143022.123.4242.42"`
   (local time, millisecond precision; `emacs-pid`; process-wide serial).
   Uniqueness: within a session by the serial; across concurrent Emacs
   processes by the pid; across restarts by the timestamp (a pid can be
   recycled, an ms timestamp with the same pid and same serial across a
   restart is for all practical purposes impossible). No coordination, no
   file scan — analytics' `--serial`/`--serial-seeded`/`--next-id`
   (~15 lines incl. reading+parsing the whole log file) are deleted.
   Alternatives rejected: (a) analytics seeds a core counter at
   registration — recouples the core to the analytics file and breaks if
   registration happens late; (b) hash of (timestamp, session buffer name,
   ordinal) — buffer names are not unique across sessions or renames, and
   the timestamp is the human-greppable, lexicographically sortable
   disambiguator anyway. Cost: `id` changes from integer to string in the
   JSONL; stats fold with `equal` keys and accept both shapes (decision 9).

5. **Observation hook with per-function error isolation in the core.**
   `gptel-permit-events-functions` is run by a core helper
   (`--run-events`) that wraps *each* function in `condition-case`, logs,
   and continues. Observers must never change a verdict; a broken logger
   must not turn an `allow` into a prompt storm. Analytics keeps its own
   wrapper too (as `--emit` has today) — belt and braces.

6. **Veto hook is a predicate chain; the core upgrades the verdict.**
   `gptel-permit-veto-functions` via `run-hook-with-args-until-success`:
   first non-nil wins, and the *core* rebuilds `(:confirm t)`, preserving
   `:args` if present. Today's verdict-reconstruction code in
   `--maybe-sample` leaves the core's protocol details where they belong,
   and arbitrary verdict rewriting by add-ons stays impossible.
   Alternative rejected: filter-style hook returning (possibly rewritten)
   verdicts — non-standard runner, silently composable rewrites are a
   footgun. Error semantics preserved: veto functions are *not* wrapped,
   so an error propagates into `--apply-rules`'s existing fail-closed
   handler, exactly as a `--maybe-sample` error does today. Likewise the
   audit event for a sampled call is emitted by the predicate itself
   (today `--maybe-sample` calls `--emit-audit` unwrapped — propagates the
   same way).

7. **Events fire at the decision point; order within a chain unchanged.**
   `:tool-call` right after minting; `:rule-match` *inside* the rule
   matcher at the moment a rule matches (or once, with nil action, after
   the loop finds nothing); `:verdict` after dispatch; `:confirm` when the
   final verdict asks. The JSONL per-chain order
   tool-call < rule-match < verdict < confirm is byte-identical in
   meaning to today. The event vocabulary is open, not a closed
   enumeration: future engine versions may add event types, delivered
   through the same hook with the same signature (the "Extensible event
   set" requirement); observers treat an unknown TYPE as data. The
   matcher is renamed
   `gptel-permit--rule-action` → `gptel-permit--find-action` (it finds;
   and it now also reports) and gains the ID argument. No alias: internal,
   `--`-prefixed, tests updated.

8. **`gptel-permit-before-rule-match-functions`: lifecycle, not an event.**
   Run once per call (after `:tool-call` is observed — observers see the
   call before any module mutates per-call state — and before matching)
   with `(ID TOOL-CALL)`. Not routed through the events hook: state
   hygiene isn't an observable decision, and silently-ignoring unknown
   event types would hide bugs. Errors propagate → fail closed: a module
   whose reset fails must not auto-run tools. The judge's reset moves here
   verbatim (minus `boundp` guards — the module defines its own vars with
   `defvar-local`), registered at judge-module load. The judge's state
   vars keep their names and buffer-local semantics; what leaves the core
   is *all* judge-knowledge (declarations, reset function, call site).

9. **Analytics stats tolerate numeric and string ids.**
   `--outcome-table` switches its hash test `eql` → `equal` and gates on
   non-nil id instead of `numberp`. Historical logs (integer ids) thus
   fold exactly as before; nothing else consumes ids arithmetically after
   seeding is gone. The stats-side `--auto-allowed-p` drops its hardcoded
   `("allow" "sandbox")` for the structural equivalent: action not
   `"none"` ∧ not asked ∧ not blocked — the runtime predicate was already
   verdict-shaped.

10. **Sandbox self-registers both integration points at load.**
    `(setf (alist-get 'sandbox gptel-permit-action-handlers) …)` for the
    action, and `add-hook 'gptel-post-tool-call-functions
    #'gptel-permit-sandbox--post-tool` for boundary-failure tracking
    (which leaves the minor mode). The post-tool function is inert when
    the mode never wrapped a command (the remember-registry is empty), so
    loading with the mode off is harmless; named functions make repeated
    loads idempotent. The sandbox action's signature becomes
    `(ID TOOL-CALL)`; the id is ignored today, reserved for judge-async.

11. **Interactive rule creation keeps `allow`/`ask`/`deny`.**
    `gptel-permit-add-rule`'s choices deliberately exclude module actions:
    an interactive "sandbox everything like this" affordance is a separate
    design question (the `C-c C-s` hotkey in sandbox-backend-registry is
    the safer shape).

## Implementation draft

Mechanics, per module. Pseudocode elided as `;; …unchanged…`.

### Core — registry and built-in handlers

```elisp
(defvar gptel-permit-action-handlers
  '((allow . gptel-permit--action-allow)
    (deny  . gptel-permit--action-deny)
    (ask   . gptel-permit--action-ask))
  "Alist mapping rule action symbols to handler functions.
A handler is called with (ID TOOL-CALL) — the decision correlation id
and the enriched tool call — and returns a verdict plist per
`gptel-pre-tool-call-functions', or nil to defer.  Modules add entries
at load time, e.g. the sandbox module adds
\(sandbox . gptel-permit--sandbox-action).  A matched action with no
registered handler fails closed: see `gptel-permit--apply-rules'.")

(defun gptel-permit--action-allow (_id _tool-call) (list :confirm nil))
(defun gptel-permit--action-deny  (_id _tool-call) (list :block "auto-denied"))
(defun gptel-permit--action-ask   (_id _tool-call) (list :confirm t))
```

### Core — ids and hooks

```elisp
(defvar gptel-permit--decision-serial 0
  "Serial component of decision ids minted in this Emacs session.")

(defun gptel-permit--mint-id ()
  "Return a fresh decision correlation id (a string).
Format TIMESTAMP.PID.SERIAL — unique across sessions (timestamp,
millisecond precision), concurrent Emacs processes (pid) and calls
within a process (serial), without any coordination."
  (format "%s.%d.%d"
          (format-time-string "%Y%m%dT%H%M%S.%3N")
          (emacs-pid)
          (cl-incf gptel-permit--decision-serial)))

(defvar gptel-permit-before-rule-match-functions nil
  "Abnormal hook run once per tool call before rule matching.
Called with (ID TOOL-CALL); return values are ignored.  Modules use it
for per-call state lifecycle (the judge clears its verdict/rationale
state here).  Errors are not caught: they fail the call closed.")

(defvar gptel-permit-events-functions nil
  "Abnormal hook observing each engine decision.
Called with (ID TOOL-CALL TYPE PAYLOAD) where TYPE is one of
:tool-call, :rule-match, :verdict, :confirm and PAYLOAD is nil, the
matched action symbol (nil when no rule matched), (ACTION . VERDICT),
or nil respectively.  Each function runs in `condition-case': an
erroring observer is logged and can never alter a verdict.")

(defvar gptel-permit-veto-functions nil
  "Abnormal hook run after a verdict is computed, before it is returned.
Called with (ID TOOL-CALL VERDICT); run via
`run-hook-with-args-until-success' and only when a rule matched.  A
non-nil return upgrades the verdict to (:confirm t), preserving any
:args rewrite.  Veto functions inspect VERDICT and can only veto; they
never return modified verdicts.  Errors fail closed.")

(defun gptel-permit--run-events (id tool-call type payload)
  "Run observers on `gptel-permit-events-functions', isolating errors."
  (dolist (fn gptel-permit-events-functions)
    (condition-case err
        (funcall fn id tool-call type payload)
      (error (gptel-permit--log "Decision observer %S failed: %S" fn err)))))
```

### Core — matcher (renamed) and the verdict chain

```elisp
(defun gptel-permit--find-action (tool-call id)
  "Return the action of the first rule matching TOOL-CALL, or nil.
Renamed from `gptel-permit--rule-action'.  Emits a :rule-match
event at the moment the match is decided."
  (catch 'found
    (dolist (rule (append gptel-permit-rules gptel-permit-global-rules))
      (when-let* ((action (gptel-permit--match-rule-p rule tool-call)))
        (gptel-permit--run-events id tool-call :rule-match action)
        (throw 'found action)))
    (gptel-permit--run-events id tool-call :rule-match nil)
    nil))

(defun gptel-permit--apply-rules (tool-call)
  "Enforce permission rules for TOOL-CALL.
Session rules first, then global; first match wins.  A matched action
dispatches through `gptel-permit-action-handlers'; an action with no
handler fails closed with (:confirm t).  No match returns nil (defer).
On unexpected error, fail closed with (:confirm t)."
  (condition-case err
      (unless (gptel-permit--processed-p tool-call)
        (let* ((enriched (gptel-permit--enrich-tool-call tool-call))
               (id (gptel-permit--mint-id)))
          (gptel-permit--log "Started rule checks …") ;; …unchanged…
          (gptel-permit--run-events id enriched :tool-call nil)
          (run-hook-with-args
           'gptel-permit-before-rule-match-functions id enriched)
          (let* ((action (gptel-permit--find-action enriched id))
                 (handler (and action
                               (cdr (assq action
                                          gptel-permit-action-handlers))))
                 (verdict
                  (cond ((null action) nil)
                        (handler (funcall handler id enriched))
                        (t (gptel-permit--log
                            "No handler for action %S — failing closed"
                            action)
                           (list :confirm t)))))
            (gptel-permit--log "Verdict: %s" (or action "none (fallback)"))
            (gptel-permit--run-events
             id enriched :verdict (cons action verdict))
            (when (and action
                       (run-hook-with-args-until-success
                        'gptel-permit-veto-functions id enriched verdict))
              (setq verdict
                    (if (plist-get verdict :args)
                        (list :confirm t :args (plist-get verdict :args))
                      (list :confirm t))))
            (when (and (consp verdict) (plist-get verdict :confirm))
              (gptel-permit--run-events id enriched :confirm nil))
            verdict)))
    (error
     (gptel-permit--log "Error in --apply-rules: %S — failing closed" err)
     (list :confirm t))))
```

Deleted from the core: `--rule-action` (renamed), `--sandbox-dispatch`,
`--post-tool-dispatch` plus its minor-mode wiring, `--reset-judge-state`,
the two bare judge `defvar` declarations, `--analytics-notify`,
`--analytics-sample`, the two sandbox `declare-function`s, and the `sandbox`
entry in the rules defcustom's `:type` widget (which gains
`(symbol :tag "Registered action")` instead).

### Sandbox module

```elisp
(defun gptel-permit--sandbox-action (id tool-call) ;; id ignored today
  "…unchanged logic…")

;; At load time, after the definitions:
(setf (alist-get 'sandbox gptel-permit-action-handlers)
      #'gptel-permit--sandbox-action)
(add-hook 'gptel-post-tool-call-functions
          #'gptel-permit-sandbox--post-tool)
```

### Judge module

```elisp
(defun gptel-permit-judge--reset-state (_id _tool-call)
  "Clear the judge's per-call verdict state in this buffer.
Runs on `gptel-permit-before-rule-match-functions' so a stale verdict
cannot leak into another call's analytics events."
  (setq gptel-permit--last-judge-rationale nil
        gptel-permit--last-judge-verdict nil))

(add-hook 'gptel-permit-before-rule-match-functions
          #'gptel-permit-judge--reset-state)
```

### Analytics module

```elisp
(defun gptel-permit-analytics--observe (id tool-call type payload)
  "Adapter from `gptel-permit-events-functions' to the emitters.
Inert unless registered+enabled; never signals."
  (when (gptel-permit-analytics--active-p)
    (condition-case err
        (pcase type
          (:tool-call  (gptel-permit-analytics--emit-tool-call tool-call id))
          (:rule-match (gptel-permit-analytics--emit-rule-match
                        tool-call id payload))
          (:verdict    (gptel-permit-analytics--emit-verdict
                        tool-call id (car payload) (cdr payload)))
          (:confirm    (gptel-permit-analytics--emit-confirm tool-call id)))
      (error (gptel-permit--log "Analytics: %s event failed: %S" type err)))))

(defun gptel-permit-analytics--audit-p (id tool-call verdict)
  "Audit predicate for `gptel-permit-veto-functions'.
Non-nil when VERDICT is an automation allow selected for sampling;
emits the audit event itself.  Errors propagate (fail closed), as they
did through `gptel-permit-analytics--maybe-sample'."
  (and (gptel-permit-analytics--active-p)
       (gptel-permit-analytics--automation-allow-p verdict)
       (< (random 100) (* gptel-permit-analytics-sample-rate 100))
       (progn (gptel-permit-analytics--emit-audit tool-call id) t)))

;; --emit-tool-call gains an ID parameter (no longer mints):
(defun gptel-permit-analytics--emit-tool-call (tool-call id)
  "Append a tool-call event for TOOL-CALL with correlation ID."
  ;; …unchanged apart from dropping (gptel-permit-analytics--next-id)…
  )

;; Registration:
(defun gptel-permit-register-analytics-hooks ()
  ;; …advice-add trio unchanged…
  (add-hook 'gptel-permit-events-functions
            #'gptel-permit-analytics--observe)
  (add-hook 'gptel-permit-veto-functions
            #'gptel-permit-analytics--audit-p)
  (setq gptel-permit-analytics--registered t
        gptel-permit-analytics-enabled t))
;; unregister: symmetric remove-hook + advice-remove + state reset.
```

Deleted from analytics: `--next-id`, `--serial`, `--serial-seeded`,
`--emit` (superseded by `--observe`), `--maybe-sample` (superseded by
`--audit-p`). Changed: `--outcome-table` hash test `eql` → `equal`, id
gate `numberp` → non-nil; `--auto-allowed-p` structural (action ≠
`"none"` ∧ not asked ∧ not blocked).

## Risks / Trade-offs

- [A sandbox rule in force while the module fails to load → previously
  fail-closed via `fboundp`; now fail-closed via missing registry entry.
  Identical semantics, but a *different* message and code path] → New
  core test for unknown actions doubles as the regression test.
- [Loading the sandbox module now touches `gptel-post-tool-call-functions`
  even with `gptel-permit-mode` off] → Inert (empty wrapped-command
  registry ⇒ no-op); documented in the module and AGENTS.org.
- [String ids break out-of-tree consumers grepping integer ids] → None
  are known; the format stays JSON-friendly and the stats reader accepts
  both. Noted in README.
- [A module registering on the wrong/renamed hook silently does nothing]
  → Hooks are defvars with docstrings; `make test` exercises the real
  module wiring end-to-end (stale-judge-leak test must pass unchanged).
- [`--find-action` emitting inside the matcher couples matching to
  observation] → Observers are per-function error-isolated and the event
  carries data only; the match result is computed before emission.

## Migration Plan

Fully additive for users' *rules*: rule plists, both rule lists, and all
defcustoms keep working; the defcustom widget change is cosmetic. Behavior
changes: unknown action values now prompt instead of deferring (hardening);
correlation ids become strings (old logs remain valid). Internal renames
(`--rule-action`, `--next-id`, `--maybe-sample`, …) have no aliases —
grep-clean in-repo. Rollback: revert the commits; no persistent state.

## Open Questions

- Should veto functions also see deferred (nil) verdicts, e.g. to sample
  tools that auto-execute with no rule at all? Deferred — today's gate
  (rule matched) is preserved deliberately.
- Pending-confirmation correlation is still keyed `(buffer tool args)`;
  re-keying on the core id would fix the rewritten-args orphaning that
  sandbox-backend-registry's decision 8 patches locally. Future cleanup.
- The `judge-async-action` amendments are tracked as tasks here, but its
  own spec deltas stay owned by that change.
