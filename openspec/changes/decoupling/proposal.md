# Proposal: decoupling

## Why

The core rule engine (`gptel-permit.el`) contains hardwired knowledge of
every optional module: a `pcase` in `gptel-permit--apply-rules` with a
bespoke `sandbox` branch plus `gptel-permit--sandbox-dispatch`, the
judge's per-call state variables and their reset function, and four
analytics call sites with two `fboundp` shims (`--analytics-notify`,
`--analytics-sample`). Conditions are extensible
(`gptel-permit--condition-predicates`), actions are not — every new
action or add-on requires editing the core, so the core can neither be
stable nor run meaningfully "with no additions" as a design contract.

## What Changes

- **Action registry.** New public alist `gptel-permit-action-handlers`
  mapping action symbols to handler functions called with
  `(ID TOOL-CALL)`, returning a verdict plist or nil (defer). The
  built-ins `allow`/`deny`/`ask` are registered entries like any other.
  The `pcase` dispatch in `gptel-permit--apply-rules` is replaced by an
  alist lookup. A matched action with *no registered handler* fails
  closed with `(:confirm t)` (today it silently defers with nil, which
  can auto-run a tool whose `:confirm` slot is nil — behavior hardening,
  **BREAKING** for nonexistent/typo'd action values).
- **Sandbox self-registers.** The sandbox module adds its action handler
  to the registry at load and registers
  `gptel-permit-sandbox--post-tool` on `gptel-post-tool-call-functions`
  itself. The core loses `gptel-permit--sandbox-dispatch`,
  `gptel-permit--post-tool-dispatch` (and its minor-mode wiring), and the
  sandbox `declare-function`s. "Sandbox module not loaded ⇒ sandbox
  rules fail closed" survives for free as "no handler registered".
- **Judge state lifecycle hook.** New abnormal hook
  `gptel-permit-before-rule-match-functions` run once per tool call
  before matching, with signature `(ID TOOL-CALL)`. The judge's reset
  function moves into `gptel-permit-judge.el` and hooks itself at load;
  the core drops `--reset-judge-state` and the bare `defvar`
  declarations of the judge's state variables.
- **Core-minted correlation ids.** The core allocates an id per tool
  call (`gptel-permit--mint-id`: `timestamp.pid.serial` string), unique
  across sessions and concurrent Emacs processes without coordination —
  replacing the analytics module's integer serial seeded by scanning its
  log file (deleted). **BREAKING** (internal): correlation ids become
  strings; the stats folding accepts both historical numeric and new
  string ids.
- **Events hook.** New abnormal hook
  `gptel-permit-events-functions`, called with `(ID TOOL-CALL TYPE
  PAYLOAD)` for `:tool-call`, `:rule-match`, `:verdict` and `:confirm`
  events, fired as close to each decision as possible (the `:rule-match`
  event moves inside the rule matcher). Observer errors are caught and
  logged; an erroring observer never alters a verdict.
- **Veto hook.** New abnormal hook `gptel-permit-veto-functions`,
  run with `run-hook-with-args-until-success` as `(ID TOOL-CALL
  VERDICT)` after the verdict is computed and only when a rule matched.
  A non-nil return makes the *core* upgrade the verdict to `(:confirm
  t)`, preserving any `:args` rewrite — verdict reconstruction moves out
  of the analytics module. Veto errors propagate into the existing
  fail-closed handler, exactly as sampling errors do today.
- **Renaming.** `gptel-permit--rule-action` → `gptel-permit--find-action`
  (verb; gains an ID argument to emit the `:rule-match` event).
- **Analytics rewired.** `gptel-permit-register-analytics-hooks` adds
  two thin adapters: `--observe` (engine events → existing emitters, a
  superset of today's `--emit`) and `--audit-p` (today's `--maybe-sample`
  minus the verdict rebuilding). The event vocabulary, JSONL schema and
  event ordering within a call's chain are unchanged.
- **Pending proposals follow the registry.** The
  `judge-async-action` change is amended so judge-form actions are a
  registered action handler resolving ON-SAFE/ON-UNSAFE through
  `gptel-permit-action-handlers`, instead of forms recognized inside
  `gptel-permit--apply-rules`.

Non-goals: changing rule syntax or matching semantics; changing the gptel
hook surface (`gptel-pre-tool-call-functions` registration, keymap);
touching the gptel-decision-capture advice trio; generalizing the
`(buffer tool args)` pending-confirmation key to ids (related, deferred).

## Capabilities

### New Capabilities
- `rule-engine-hooks`: the core's extension contract — core-minted unique
  correlation ids, the three abnormal hooks
  (`gptel-permit-before-rule-match-functions`,
  `gptel-permit-events-functions`, `gptel-permit-veto-functions`) with
  their uniform `(ID TOOL-CALL …)` signature prefix, firing points
  relative to matching/verdict construction, and error semantics
  (observers isolated, veto propagates fail-closed). The event type set
  is open: additional engine events are emitted through the same hook
  with the same signature.

### Modified Capabilities
- `rule-engine`: action dispatch is registry-driven; unknown actions
  fail closed; the verdict chain (match → verdict → veto → confirm) is
  defined independently of any optional module.
- `sandbox`: the module registers its action handler and its boundary-
  failure tracking itself; no sandbox symbols remain in the core.
- `llm-judge`: the judge owns and resets its per-call state via
  `gptel-permit-before-rule-match-functions`; no judge symbols remain in
  the core.
- `analytics`: correlation ids arrive from the core as strings; the
  serial/seeding machinery is removed; capture and audit sampling ride
  the two core hooks; statistics tolerate numeric and string ids.

## Impact

- **Code**: `gptel-permit.el` (≈120 lines churn: registry, mint-id, three
  hooks, `--apply-rules` rebuild, deletions; net shrinkage),
  `gptel-permit-sandbox.el`, `gptel-permit-judge.el`,
  `gptel-permit-analytics.el`, the four test suites, README,
  AGENTS.org, and the pending `judge-async-action` proposal/design.
- **Hook pipeline**: `gptel-pre-tool-call-functions` registration is
  unchanged (`gptel-permit--validate-args`, then
  `gptel-permit--apply-rules`). `gptel-post-tool-call-functions` is now
  touched by the sandbox module at load (inert unless the mode wrapped a
  command) instead of by the minor mode. Three new internal hooks appear
  on gptel-permit's own side of the boundary.
- **Rule matching**: unchanged — session rules before global rules,
  first match wins, all conditions must match. Only *dispatch* of a
  matched rule's action changes owner; an unmatched call still returns
  nil (defer).
- **Public API / stability surface**: `gptel-permit-action-handlers` and
  the three hook variables become the documented contract add-ons code
  against. The judge-state variables remain internal to
  `gptel-permit-judge`.
- **Failure modes**: preserved or hardened — every removed
  `fboundp`-shim has a fail-closed equivalent; observer errors are
  isolated per function; veto errors fail closed; the core with zero
  modules behaves exactly as today (rules, validation, path-traversal
  checks all core-owned).
