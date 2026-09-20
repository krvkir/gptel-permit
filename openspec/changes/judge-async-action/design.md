## Context

Today the judge exists only as a sync *condition*
(`gptel-permit-judge-safe-p`): rule matching calls it inline, it blocks up
to `gptel-permit-judge-timeout` seconds in `accept-process-output`, freezing
Emacs for the judge's latency. gptel's hook protocol
(`gptel-pre-tool-call-functions`, `gptel--handle-pre-tool`) is synchronous:
a hook returns a verdict plist immediately; there is no deferred-verdict
mechanism (that is what the optional `judge-async-defer` change adds, via a
gptel patch).

But gptel already has a supported async boundary: `(:confirm t)`. The FSM
parks in TOOL state, `gptel--display-tool-calls` shows the prompt overlay
(a `prompt-ov` with `before-string`/`after-string`, chained on the tool
overlay's `prompt` property), pending calls are triples
`(tool-spec args process-tool-result)` on the overlay's `gptel-tool`
property, and `gptel--accept-tool-calls (&optional tool-calls ov)` accepts
possibly-edited triples — programmatically. `gptel--steer-tool-calls`
demonstrates the reject-continue path: feed a result string through each
pending triple's `process-tool-result`, then clean up overlay + prompts.
This change uses only that documented surface, so gptel stays untouched.

Design constraint from review: the primary goal is unfreezing *other*
buffers. The session buffer showing a prompt during the wait is acceptable;
we do not add machinery to suppress it here.

## Goals / Non-Goals

**Goals:**
- Zero UI freeze during judging; Emacs stays fully usable everywhere.
- The async judge with no gptel modifications (prompt-while-judging accepted
  as the interim tradeoff).
- A verdict-dependent action grammar covering both SAFE and UNSAFE, with
  sane defaults (`judge` = allow/ask).
- Rule semantics stay first-match-wins with no exceptions: the judge
  action resolves the matched rule; conditions alone decide matching.
- Fail-closed everywhere: judge failure ⇒ manual confirmation; no verdict
  application when the user already answered.

**Non-Goals:**
- Removing or changing the sync condition form
  (`gptel-permit-judge-safe-p` stays, sync, for conservative users).
- Invisible parking of judged calls (the optional `judge-async-defer`
  change; only if prompt-flash proves annoying).
- Partial pack acceptance (packs resolve as a whole or not at all).
- Retrying failed judge requests automatically.

## Decisions

1. **Action grammar: `judge` | `(judge A)` | `(judge ON-SAFE ON-UNSAFE)`.**
   The `:action` slot value becomes: an action symbol (`allow`, `deny`,
   `ask`, `sandbox`), `judge`, or a *list* whose car is `judge` followed by
   one or two action symbols. Defaults: `judge` ≡ `(judge allow ask)`;
   `(judge A)` ≡ `(judge A ask)`. All four actions are valid in both
   verdict slots: `deny` on UNSAFE gives the judge real blocking power;
   `sandbox` on UNSAFE is meaningful too ("judge says dangerous — run it
   confined instead of asking", e.g. `(judge allow sandbox)`). Malformed
   forms (wrong arity, unknown symbols) log a warning and resolve as
   `ask`.
   *Note on naming:* the existing deny action symbol is `deny`
   (`gptel-permit--apply-rules` maps it to `(:block "auto-denied")`); the
   judge grammar reuses it rather than introducing `block`.

2. **The judge resolves, conditions match.** A rule with a judge action
   matches when its conditions match, exactly like any rule — the judge
   plays no part in matching. Once matched, the rule owns the call: SAFE
   applies ON-SAFE, UNSAFE applies ON-UNSAFE, and evaluation stops (no
   fall-through to later rules in any mode). Judge evaluation failure
   (timeout, parse-fail, request-fail) resolves to manual confirmation —
   *not* to ON-UNSAFE, because ON-UNSAFE expresses "the judge answered
   unsafe", not "the judge is unreachable"; auto-rejecting on a timeout
   would silently deny calls the judge never saw.
   *Consequence:* the sync condition form keeps its role for
   fall-through-style gating ("this rule only applies if the judge approves
   — otherwise let later rules decide"); the action form is for "this rule
   owns the call, the judge picks the resolution".

3. **`deny` resolutions carry the rationale.** A `deny` resolution produces
   a block reason that includes the judge's rationale (sync: the `:block`
   verdict string; async: the rejected result string), so the LLM learns
   *why* the call was declined and can adjust. Sync `deny` maps to
   `(:block (format "Judge rejected: %s" rationale))`.

4. **Sync and async share one verdict→action mapping.** A single function
   maps `(verdict on-safe on-unsafe)` → resolution verdict plist:
   SAFE → action verdict of ON-SAFE (sandbox goes through the adapter
   registry); UNSAFE → action verdict of ON-UNSAFE; failure →
   `(:confirm t)`. Sync mode calls it inline after the blocking request;
   async mode calls it from the callback. Only the request timing differs.

5. **Async mode returns `(:confirm t)` and resolves from the callback.**
   `gptel-permit-judge-async` (default t): the hook stashes per-call context
   `(buffer tool-call-identity on-safe on-unsafe timer issued-at)`, fires
   the non-blocking judge request, and returns `(:confirm t)`. The callback
   re-enters with `with-current-buffer`, parses the verdict, sets the
   judge state vars (for analytics consumers), and applies the mapping.
   *Tradeoff accepted:* the confirmation prompt is visible during judging
   and vanishes on auto-accept. Mitigations: the "judging…" indicator
   (decision 6) labels the prompt, and a transient message notes each
   programmatic resolution.

6. **Judging indicator on the prompt overlay.** While judging, a small
   indicator ("⏳ judging…", `font-lock-doc-face`) is shown in the prompt.
   Mechanics: gptel's `gptel--display-tool-calls` chains prompt overlays on
   the tool overlay's `prompt` property; permit stacks its own zero-width
   overlay at the prompt overlay's start position with a `before-string`,
   and deletes it on resolution. Cheap (≈10 lines), touches no gptel-owned
   buffer text.

7. **Pack resolution is all-or-nothing and uniform.** gptel accepts or
   rejects whole packs (accept deletes the overlay and all prompts). The
   callback therefore applies programmatic resolutions only when every
   pending call in the pack is judge-gated and all resolutions are
   uniform:
   - all accept-class (allow, or sandbox with args rewritten through the
     adapter registry) → `gptel--accept-tool-calls` with the rewritten
     triples;
   - all `deny` → feed each pending triple's `process-tool-result` the
     rationale-bearing rejection (the steer pattern), then clean up
     overlay + prompts;
   - anything else (an `ask` resolution, a mixture, a non-judged call, a
     failure, an audit-sampled call) → the pack stays on the prompt.
   Per-call verdicts are recorded regardless (analytics), so a mixed pack
   logs every verdict while the human decides.

8. **Watchdog timer per pending judge call.** Async judge requests have no
   built-in timeout; each stash arms a `run-at-time` at
   `gptel-permit-judge-timeout` seconds that resolves the call as `timeout`
   (leaves the prompt). The callback cancels the timer. The timer resolves
   *our stashed state* only; a stray late gptel response hits the
   already-resolved guard and is discarded + logged.

9. **Analytics: `judge-verdict` events + programmatic decisions +
   sampling suppression.**
   - The callback emits a `judge-verdict` event (same correlation id as the
     tool-call event; fields: verdict incl. failure classes, rationale,
     judged arg value, latency) — emitted from the verdict-owning buffer so
     the judge state vars are current.
   - Programmatic resolutions emit `decision` events with choices
     `auto-allow` (pack auto-accept) and `deny` (pack auto-reject), distinct
     from user choices (`allow`/`cancel`/`steer`); the pending-confirmation
     entry is popped with the *pre-rewrite* args (the sandbox-registry
     analytics requirement).
   - Audit sampling extends to judge-gated calls: when sampling selects
     the call, an `audit` event is emitted, the judge still runs and its
     verdict is logged, but the resolution is forced to the manual
     confirmation — no programmatic accept or reject, whatever the verdict.
     This measures judge false-positives (SAFE→allow that a human would
     reject) and false-UNSAFE rates alike.
   - `gptel-permit-analytics--action-string` serializes list-form judge
     actions (e.g. `(judge sandbox deny)` → `"judge:sandbox/deny"`) so
     rule-match/verdict events stay well-formed.

## Implementation (mechanics deliberately kept out of the requirements)

- Dispatch site: `gptel-permit--apply-rules` recognizes the judge forms in
  the action slot; validation of the grammar happens at rule-evaluation
  entry (malformed → warn + effective `ask`).
- Mapping: `gptel-permit--judge-action-verdict (verdict on-safe on-unsafe)`
  → resolution plist (shared by sync and async).
- Stash: `gptel-permit--judge-pending` buffer-local alist keyed on
  `(tool name + args equal)`; entries carry on-safe/on-unsafe, the armed
  timer, and the issue timestamp.
- Overlay lookup: scan the buffer's overlays for the `gptel-tool` property
  whose triples contain the stashed call identity (the
  `gptel-permit-add-rule` pattern); resolve only when the pack matches
  decision 7's uniformity rule.
- Reject path: `gptel-permit--reject-pending (tool-calls ov reason)` —
  `(dolist ((_ _ cb) tool-calls) (funcall cb reason))` then the same overlay
  + prompt cleanup `gptel--steer-tool-calls` performs (its `read-string` is
  why we cannot reuse it directly).
- Guards on every callback path: buffer-live, overlay-live, call lacks
  `:result`, stash not already resolved; each no-op logs.

## Risks / Trade-offs

- [Prompt flash + user race: user accepts before the verdict → call runs
  unwrapped] → Documented behavior: a manual accept is an explicit human
  override, the callback's already-resolved guard discards the stale
  verdict. The judge-gated auto path only ever *reduces* exposure.
- [Multiple concurrent judge requests for one pack (one per judged call)]
  → Independent stash entries; uniformity gating (decision 7); timer per
  entry. Cost: N small requests in flight — acceptable for pack sizes ≤ a
  handful.
- [Callback lands after the buffer/overlay is killed] → liveness guards
  no-op with a log line; gptel's own FSM cleanup is unaffected.
- [Judge action in sync mode keeps the freeze] → Sync mode is opt-out
  (`gptel-permit-judge-async` nil) for users who prefer blocking over the
  prompt flash; not the default.

## Migration Plan

Additive DSL: judge-form rules simply start working; existing rules and the
condition form are untouched. Default `gptel-permit-judge-async = t` affects
only judge-form rules (none can exist before this change). Rollback: set
`gptel-permit-judge-async` nil or revert.

## Open Questions

- `gptel-agent` sessions: they run their own tool-call loop; judge-action
  async applies to `gptel-send` packs first, and the agent integration is
  re-checked during implementation (same caveat for `judge-async-defer`).
- Should the judging indicator also appear in the mode line (via
  `gptel--update-status`) when point is far from the prompt? Deferred; the
  overlay indicator is the committed scope.
