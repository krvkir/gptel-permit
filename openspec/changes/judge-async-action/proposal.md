## Why

The judge is currently only usable as a sync condition: the whole interface
freezes in `accept-process-output` for the judge's latency (seconds). The tool
caller process should wait for the judge, not the user. Making the judge an
*action* — `(judge . allow)` / `(judge . sandbox)` — gives a clean async
shape with **zero changes to gptel**: the hook returns `(:confirm t)`
immediately, the pending-confirmation UI appears, and a judge callback
auto-accepts the call when the verdict is SAFE. The prompt-while-judging
tradeoff (visible confirm that auto-vanishes on SAFE) is accepted for now; the
later `judge-async-defer` change replaces the prompt-park with an invisible
park via a small gptel patch.

## What Changes

- New rule action form `(judge . ACTION)` with `ACTION` ∈ `allow`, `sandbox`:
  the rule matches on its conditions as usual, but the verdict comes from the
  judge — SAFE applies ACTION, UNSAFE or any failure falls through to later
  rules (first-match-wins is preserved: the judge rule itself is not re-run,
  evaluation continues *after* it).
- `gptel-permit-judge-async` defcustom (default `t`): async mode as described;
  `nil` runs the judge action synchronously (blocking, identical UX to the
  condition form today). The existing *condition* form
  (`gptel-permit-judge-safe-p` in `:conditions`) remains unchanged and
  synchronous.
- Async flow: the hook fires a `gptel-request` (non-blocking) and returns
  `(:confirm t)`; a watchdog timer (`gptel-permit-judge-timeout`) resolves
  the pending call as failed if no response arrives. The callback stashes its
  pending-call context (buffer, tool-call, action) before the request.
- Callback resolution: SAFE → locate the pending-confirmation overlay by
  tool-call identity; **auto-accept the pack only if every pending call in the
  pack is judge-gated and has a SAFE verdict** (a pack containing any
  non-judged call stays on the prompt — no auto-running calls the judge never
  saw). `(judge . sandbox)` rewrites the args through the sandbox adapter
  registry before accepting. UNSAFE/failure/timeout → leave the prompt for
  the human (fail-closed by inaction) with a log line and a transient
  message.
- Race guards: the callback no-ops when the buffer is dead, the overlay is
  gone, or the stashed call already has a result (the user acted first — their
  decision wins).
- Analytics: a new `judge-verdict` event type records the verdict/rationale
  when the async verdict lands (correlated with the original tool-call id);
  a programmatic auto-accept records a `decision` event with
  `choice: auto-allow`. The per-call judge state vars
  (`gptel-permit--last-judge-verdict` etc.) are set by the callback with
  `with-current-buffer` for audit consumers.

## Capabilities

### New Capabilities
- `judge-action`: the `(judge . ACTION)` rule action — matching semantics,
  SAFE/UNSAFE resolution, sync/async modes, pack auto-accept gating, and the
  sandbox handoff.

### Modified Capabilities
- `rule-engine`: `:action` gains the `(judge . ACTION)` cons form in its
  action space; first-match-wins evaluation gains one exception: a judge
  action that does not resolve SAFE continues scanning from the next rule.
- `analytics`: event schema gains the `judge-verdict` type; programmatic
  auto-accepts are recorded as decisions with an `auto-allow` choice distinct
  from user `allow`.
- `llm-judge`: async request mode and the watchdog reuse the failure classes
  from `judge-logging-thinking`; the condition form is untouched.

## Impact

- Code: `gptel-permit-judge.el` (async request path, callback resolution,
  watchdog), `gptel-permit.el` (action cons dispatch in `--apply-rules`,
  continue-scan-after-judge rule evaluation), `gptel-permit-analytics.el`
  (`judge-verdict` event type, `auto-allow` decision choice), README.
- Hook pipeline: `gptel-pre-tool-call-functions` contract unchanged —
  async mode just returns `(:confirm t)`; all gptel interaction happens via
  the documented pending-confirmation overlay (`gptel--accept-tool-calls`
  with possibly-edited triples).
- Dependencies: builds on `judge-logging-thinking` (failure classes,
  `gptel-permit-judge-request-params`) and `sandbox-backend-registry` (adapter
  registry for `(judge . sandbox)`); must be implemented after both. The
  follow-up `judge-async-defer` change supersedes this one's
  prompt-while-judging mechanics without changing the rule DSL.
