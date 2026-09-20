## Context

Today the judge exists only as a sync *condition*
(`gptel-permit-judge-safe-p`): rule matching calls it inline, it blocks up to
`gptel-permit-judge-timeout` seconds in `accept-process-output`, freezing
Emacs for the judge's latency. gptel's hook protocol
(`gptel-pre-tool-call-functions`, `gptel--handle-pre-tool`) is synchronous:
a hook returns a verdict plist immediately; there is no deferred-verdict
mechanism (that is what `judge-async-defer` adds, via a gptel patch).

But gptel already has a supported async boundary: `(:confirm t)`. The FSM
parks in TOOL state, the callback receives `(tool-call . ((tool-spec args
process-tool-result)…))` triples, `gptel--display-tool-calls` shows the
prompt overlay, and `gptel--accept-tool-calls (&optional tool-calls ov)`
accepts possibly-edited triples — programmatically. This change uses only
that documented surface, so gptel stays untouched.

Judge-as-an-*action* (`(judge . allow)` / `(judge . sandbox)`) vs the
condition form: a condition answers "does this rule match?" and its nil
already falls through to later rules — but only synchronously. An action
answers "what should happen?" and its application can be deferred: the hook
can emit the prompt immediately and apply the judge's chosen action from a
callback once the verdict lands. The rule DSL keeps the deny-only
rationale: SAFE applies the paired action; UNSAFE/failure = fall through.

## Goals / Non-Goals

**Goals:**
- Zero UI freeze during judging; the buffer stays fully usable.
- The async judge with no gptel modifications (prompt-while-judging accepted
  as the interim tradeoff).
- Preserved first-match-wins semantics: UNSAFE/failure continues the scan
  from the rule after the judge rule.
- A SAFE verdict that pairs with `sandbox` hands off to the sandbox adapter
  registry (args rewritten before acceptance).
- Fail-closed everywhere: no verdict (timeout, parse-fail, request-fail,
  user race lost) ⇒ the call stays on the prompt.

**Non-Goals:**
- Removing or changing the sync condition form
  (`gptel-permit-judge-safe-p` stays, sync, for conservative users).
- Invisible parking of judged calls (the `judge-async-defer` change).
- Multi-call partial acceptance: the pack is accepted only as a whole
  (see decision 4).
- Retrying failed judge requests automatically.

## Decisions

1. **Action cons `(judge . ACTION)` with `ACTION` ∈ {allow, sandbox}.**
   The rule engine dispatches on a cons action whose car is `judge`.
   *Why an action, not a condition:* conditions are evaluated inside rule
   matching and must return a boolean synchronously; actions are applied by
   the hook and their *application* can be scheduled asynchronously. The
   cons form pairs the judge with its success action — the only two actions
   that make sense (ask/deny need no judge; a judge that denies is the
   existing deny-only condition's job).
   *Alternative rejected:* `:action judge` + a separate `:on-safe` rule key —
   two keys to validate instead of one cons cell.

2. **Async mode returns `(:confirm t)` and resolves from the callback.**
   `gptel-permit-judge-async` (default t): the hook stashes
   `(buffer tool-call action)` context, fires the async `gptel-request`, and
   returns `(:confirm t)`. The request callback re-enters with
   `with-current-buffer`, parses the verdict, sets
   `gptel-permit--last-judge-verdict`/`rationale` (for analytics), and
   resolves. `nil` (sync mode) evaluates the action with the existing
   blocking request path — same latency as the condition form, same
   semantics, one code path for verdict→action mapping.
   *Tradeoff accepted:* the confirmation prompt is visible during judging
   and vanishes on auto-accept. Mitigation: the prompt overlay displays a
   "judging…" status line via `gptel--update-status`-style messaging, and a
   transient message notes when a judge auto-accept happens. Users who
   can't tolerate the flash keep sync mode until `judge-async-defer`.

3. **Watchdog timer per pending judge call.** Async `gptel-request` has no
   built-in timeout; the hook arms a `run-at-time` at
   `gptel-permit-judge-timeout` seconds that resolves the stash as
   `timeout` (failure class from `judge-logging-thinking`), leaving the
   prompt. The callback cancels the timer. *Why a timer, not gptel's
   request timeout:* gptel's abort machinery kills the request object and
   callback routing; the timer resolves our *stashed state* independently
   of whether gptel later delivers a stray response (which the
   already-resolved guard discards).

4. **Pack auto-accept only when every pending call is judge-gated SAFE.**
   gptel's pending confirmations come as a pack (all calls of the round
   under one overlay), and `gptel--accept-tool-calls` runs the whole list
   it is given. Auto-accepting a pack that contains a non-judged call would
   auto-run a call the judge never saw — unacceptable. So: each judge
   callback records its verdict against the stashed call; acceptance fires
   only when all pending triples in the pack carry SAFE verdicts;
   otherwise each callback leaves the prompt (with a message once the pack
   is fully judged if some verdict was negative). UNSAFE calls stay for
   the human exactly as they would without the judge.
   *Alternative rejected:* per-call acceptance — gptel's overlay/accept
   machinery is pack-granular; partial acceptance would desync the prompt
   UI from the FSM.

5. **Resolution mechanics (the callback body).** The callback resolves the
   stash by identity — buffer live, then scan the buffer's overlays for the
   `gptel-tool` property whose triples contain a call matching the stashed
   tool-call identity (tool name + args `equal`). On match: rewrite args via
   the sandbox adapter registry for `(judge . sandbox)` (reusing
   `sandbox-backend-registry`'s dispatch; adapterless/unavailable → treat as
   failure, stay on prompt, message), then `gptel--accept-tool-calls` with
   the modified triples. Guard: if the stashed call (or any triple) already
   has `:result`, the user acted first — no-op, log it.
   *Why overlay-scan, not point:* the callback must find the pack without
   user interaction; `gptel-permit-add-rule` already demonstrates the
   `gptel-tool` overlay property pattern.

6. **Rule evaluation: judge action participates in matching, not verdict.**
   In the rule scan, a `(judge . ACTION)` rule matches when its conditions
   match (like any rule); the *verdict* it produces is either
   `(:confirm t)` (async mode: prompt + judge decides) or the judged verdict
   (sync mode). If the judge resolves UNSAFE/failure **after** the hook
   returned, evaluation does **not** re-run the whole rule scan on the
   callback thread (session rules may have changed); the documented
   semantics are: fall-through happens *logically* — the judge action's
   failure means "this rule's action is not applied"; since the prompt is
   already up, the human is the fallback, exactly as a bare ask rule.
   Sync mode keeps the in-hook fall-through (scan continues from the next
   rule) because it is still inside the original scan.
   *This asymmetry is deliberate:* async fall-through would require re-entrant
   rule evaluation from the callback with a stale snapshot — the human on
   the prompt is a strictly safer fallback.

7. **Analytics: `judge-verdict` event + `auto-allow` decision.** The hook
   still emits `tool-call`/`rule-match`/`verdict`/`confirm` (verdict =
   ask). The callback emits a new `judge-verdict` event (same `:id`,
   carrying verdict + rationale + judged arg). A programmatic
   auto-accept emits `decision` with `choice: auto-allow` (distinct from
   user `allow`), keyed on the pre-rewrite args per the
   `sandbox-backend-registry` analytics requirement. False-allow audit
   sampling does not apply to judge auto-accepts (they already have a
   safety classifier; sampling stays on deterministic allows).

## Risks / Trade-offs

- [Prompt flash + user race: user accepts before the verdict → call runs
  unwrapped] → Documented behavior: a manual accept is an explicit human
  override, the callback's already-resolved guard discards the stale
  verdict. The judge-gated auto path only ever *reduces* exposure.
- [Multiple concurrent judge requests for one pack (one per judged call)]
  → Independent stash entries; acceptance gated on all-SAFE (decision 4);
  timer per entry. Cost: N small requests in flight — acceptable for pack
  sizes ≤ a handful.
- [Callback lands after the buffer/overlay is killed] → liveness guards
  no-op with a log line; gptel's own FSM cleanup is unaffected.
- [Sync mode duplicates judge→action mapping] → Single mapping function
  shared by both modes; only the request timing differs.

## Migration Plan

Additive DSL: rules with `(judge . ACT)` actions simply start working;
existing condition-form rules are untouched. Default `gptel-permit-judge-async
= t` changes the UX of any `(judge . ACT)` rules only (none can exist before
this change). Rollback: set `gptel-permit-judge-async` nil or revert.

## Open Questions

- Should the prompt overlay show a distinct "pending judge" indicator
  (e.g. a "(judging…)" suffix in the prompt text)? Implementation detail —
  cheap via the prompt overlay, decided during coding.
- `gptel-agent` sessions: they run their own tool-call loop; judge-action
  async applies to `gptel-send` packs first, and the agent integration is
  re-checked during implementation (same caveat for `judge-async-defer`).
