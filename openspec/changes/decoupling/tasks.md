# Tasks: decoupling

Ordering note: groups 1–3 are purely additive and keep the whole ERT suite
green at every commit. Group 4 is the one atomic cutover: 4.1–4.5 land
together (the suite is red between 4.1 and 4.4 by design, green again at
4.5); split commits only inside that group if each intermediate state is
loadable.

## 1. Core: add extension points (no behavior change)

- [x] 1.1 Add `gptel-permit-action-handlers` (public defvar) and the three
      built-in handlers `gptel-permit--action-allow` / `--action-deny` /
      `--action-ask` (signature `(ID TOOL-CALL)`, verdicts unchanged)
- [x] 1.2 Add `gptel-permit--tool-call-serial` and `gptel-permit--mint-tool-call-id`
      (`TIMESTAMP.PID.SERIAL`, millisecond precision via `%3N`)
- [x] 1.3 Add the three hook defvars
      (`gptel-permit-before-rule-match-functions`,
      `gptel-permit-events-functions`, `gptel-permit-veto-functions`)
      with docstrings per design, and `gptel-permit--emit-event`
      (per-function `condition-case` isolation)
- [x] 1.4 Unit tests (tests/gptel-permit-rule-engine-test.el or a new
      tests/gptel-permit-rule-engine-hooks-test.el): mint-tool-call-id format regexp +
      uniqueness in-session; registry defaults map allow/deny/ask;
      `--emit-event` isolates an erroring observer (later observer still
      runs); `make test` stays green

## 2. Sandbox module: self-register at load

- [x] 2.1 Change `gptel-permit--sandbox-action` signature to
      `(id tool-call)` (id ignored for now; docstring notes it is reserved
      for judge-async correlation); update direct callers/tests to pass a
      dummy id
- [x] 2.2 After the definitions: `(setf (alist-get 'sandbox
      gptel-permit-action-handlers) #'gptel-permit--sandbox-action)` and
      `(add-hook 'gptel-post-tool-call-functions
      #'gptel-permit-sandbox--post-tool)`
- [x] 2.3 Tests: registry entry present after load; post-tool function on
      the gptel hook after load; double-load stays single-registered
      (sandbox spec "Sandbox self-registration" scenarios)

## 3. Judge module: own its state lifecycle

- [x] 3.1 Add `gptel-permit-judge--reset-state (_id _tool-call)` to
      `gptel-permit-judge.el` (plain `setq` of the two `defvar-local`
      vars; no `boundp` guards) and `add-hook` it onto
      `gptel-permit-before-rule-match-functions` at load
- [x] 3.2 Test: hook membership after load; the existing stale-verdict
      leak scenario (analytics test ~line 466) still passes once 4.x lands
      — keep it unchanged as the acceptance test

## 4. Chain cutover (atomic: 4.1–4.5 land together)

- [x] 4.1 Core: rename `gptel-permit--rule-action` →
      `gptel-permit--find-action` with `(ID TOOL-CALL)` signature emitting
      the `:rule-match` event inside the matcher (on match and, with nil
      action, after the loop); update test call sites
- [x] 4.2 Core: rebuild `gptel-permit--apply-rules` per design — mint id,
      `:tool-call` event, run before-match hook, registry dispatch with
      fail-closed unknown-action branch, `:verdict` event, veto
      until-success upgrade preserving `:args`, `:confirm` event; rewrite
      the docstring to be module-agnostic
- [x] 4.3 Core deletions: `--sandbox-dispatch`, `--post-tool-dispatch` and
      its minor-mode wiring, `--reset-judge-state`, the two bare judge
      `defvar` declarations, `--analytics-notify`, `--analytics-sample`,
      the sandbox `declare-function`s, the action `pcase`; rules defcustom
      `:type` — drop the `sandbox` const, add `(symbol :tag "Registered
      action")`
- [x] 4.4 Analytics: `--observe` and `--audit-p` adapters; 
      `--emit-tool-call` takes an ID parameter; delete `--emit`,
      `--maybe-sample`, `--next-id`, `--serial`, `--serial-seeded`;
      `--outcome-table` hash test `eql` → `equal` with non-nil id gate;
      `--auto-allowed-p` structural (action ≠ `"none"` ∧ not asked ∧ not
      blocked); `gptel-permit-register-analytics-hooks` /
      `-unregister-analytics-hooks` add/remove the two core hooks
- [x] 4.5 `make test` green; byte-compile all four modules with no new
      warnings (in particular: no free-variable warnings for judge state
      anywhere)

## 5. Behavior tests for the new contracts

- [x] 5.1 Core: registered custom action dispatches; unregistered action →
      `(:confirm t)` even when the tool's `:confirm` slot is nil;
      handler returning nil → defer; session-over-global precedence intact
- [x] 5.2 Core: before-match hook runs after `:tool-call` and before
      matching (ordering probe); erroring before-match function →
      `(:confirm t)`; erroring veto predicate → `(:confirm t)`; veto
      upgrade preserves `:args`; veto predicate not consulted when no rule
      matched; all engine hooks nil → verdicts and returns unchanged
      (no observers needed)
- [x] 5.3 Analytics: registration asserts observer/audit-predicate
      hook membership and removal on unregister; string-id end-to-end
      chain; mixed legacy-integer + new-string id log folds correctly in
      `gptel-permit-analytics-compute`

## 6. Amend the pending judge-async-action proposal

- [x] 6.1 design.md "Dispatch site" bullet: judge forms are recognized by a
      `judge` action *handler* registered in `gptel-permit-action-handlers`
      (not inside `--apply-rules`); the handler receives the tool-call
      id that correlates its `judge-verdict` events
- [x] 6.2 Decisions 4 and 7: sub-action resolution (ON-SAFE/ON-UNSAFE)
      dispatches through `gptel-permit-action-handlers` (the action
      registry), distinct from the sandbox tool-adapter registry of
      sandbox-backend-registry — amend the wording and its
      "adapter registry" references
- [x] 6.3 Add an explicit dependency note: judge-async-action builds on
      decoupling (handler signature `(ID TOOL-CALL)`, veto hook gating for
      sampled judge calls)

## 7. Documentation and verification

- [x] 7.1 README: extension points section (action registry, the three
      hooks, uniform `(ID TOOL-CALL …)` signature, registering a custom
      action example); note the id format change
- [x] 7.2 AGENTS.org: update project-structure bullets (sandbox
      self-registration, analytics riding core hooks), the integration
      surface list (three new hooks; the minor mode no longer touches
      `gptel-post-tool-call-functions`), and fix the stale "the entire
      package is one file" line
- [x] 7.3 Final gate: `make test` green; `emacs-lisp-byte-compile` clean on
      all four modules; `grep -R "gptel-permit--\(rule-action\|sandbox-dispatch\|reset-judge-state\|analytics-notify\|analytics-sample\|post-tool-dispatch\)"` returns nothing outside openspec docs

