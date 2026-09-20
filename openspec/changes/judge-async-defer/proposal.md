## Why

`judge-async-action` removes the UI freeze but parks judged calls on the
confirmation prompt while judging: the prompt flashes, the user can race the
judge, and UNSAFE verdicts leave a prompt where none was semantically
needed. gptel has no deferred-verdict hook mechanism — a hook must return
its verdict synchronously — so we add one: a small, upstreamable patch to
gptel (~10 lines across three functions plus a resolver helper) that lets a
pre-tool hook mark a call as pending-resumption, keeps the FSM parked
invisibly until the verdict arrives, and re-runs the tool-use state with the
merged verdict. With it, judging is both asynchronous *and* invisible: no
prompt, no race, no rules silently dropped.

## What Changes

- **gptel patch (~/repos/emacs/gptel)**, upstreamable and feature-detected:
  1. `gptel--handle-pre-tool` honors a new hook-result key `:defer` — it
     puts `(:defer t)` on the tool-call plist and applies nothing else for
     that call (the existing merge branches no-op on a defer verdict).
  2. `gptel--handle-tool-use` skips deferred calls: they are neither
     executed nor added to the pending-confirmation list (no prompt).
  3. New helper `gptel--resolve-tool-call (fsm tool-call verdict)`: merges
     the verdict into the tool-call plist through the same paths the hook
     merge uses (`:confirm` → plist-put; `:args`/`:name` →
     `gptel--inject-tool-call` + `gptel--merge-plists`; `:block` → error
     result processing), clears `:defer`, and transitions the FSM directly
     to TOOL (skipping TPRE so hooks never see rewritten args — matching
     the sync path where the post-hook merge goes straight to TOOL).
  4. The hook plist gains `:fsm` (the request's FSM) so permit callbacks can
     reach the resolver; a feature flag (`gptel--tool-call-defer-p` boundp
     check) enables detection.
  - No patch to `gptel--process-tool-call` is needed: the remaining-count
    (`(not (plist-get call :result))`) already includes deferred calls, so
    the FSM naturally parks in TOOL while a deferred call is unresolved.
  - The patch is documented in the gptel repo as a dated design note
    (that repo's convention).
- **permit side**: `gptel-permit-judge-async` gains the value `defer` (and
  `auto`): in defer mode, the judge-action hook stashes
  `(fsm tool-call rule-index action timer)`, fires the async judge request,
  and returns `(:defer t)`. The callback resolves:
  - SAFE → `gptel--resolve-tool-call` with the paired action's verdict
    (`sandbox` args rewritten through the adapter registry first);
  - UNSAFE/failure/timeout → re-scan rules starting at the stashed
    rule-index+1 (current rule state, synchronous, no new judge request)
    and resolve with the first matching rule's verdict — or with an empty
    verdict (gptel's own confirm defaults) when no later rule matches;
  - user abort/buffer dead/call already `:result`ed → no-op with a log line.
- **Mode default**: `gptel-permit-judge-async` becomes `auto` — `defer` when
  the patched gptel is detected, else `prompt` (the `judge-async-action`
  mechanics), else configurable `nil` (sync). `prompt` remains available as
  an explicit choice.
- **Analytics**: verdict events now carry a `judge-latency-ms` field (verdict
  arrival minus request issue); auto-accepts are recorded as `auto-allow`
  decisions exactly as in `judge-async-action`.

## Capabilities

### New Capabilities
- `tool-call-defer`: the deferred pre-tool-verdict protocol — the `:defer`
  hook contract, the parked-while-unresolved invariant (no execution, no
  prompt, no partial LLM round-trips), and the resolver semantics. Written
  as a consumer-side contract (gptel-permit's expectations of the gptel
  patch).

### Modified Capabilities
- `judge-action`: the async resolution requirement gains the defer mode —
  invisible park instead of prompt-park, callback-driven resolution via the
  resolver, and UNSAFE fall-through to later rules (which `prompt` mode
  deliberately lacks).
- `llm-judge`: the async request mode requirement gains the defer-mode
  watchdog behavior (timeout resolves via the resolver with fall-through,
  not by leaving a prompt).

## Impact

- Code: gptel.el + gptel-request.el (the four patch hunks; upstreamable),
  gptel-permit.el (defer verdict emission, rule-index capture, stash),
  gptel-permit-judge.el (defer-mode callback, fall-through re-scan),
  gptel-permit-analytics.el (latency field), README (mode table).
- Hook pipeline: one new hook-result key (`:defer`), additive; hooks without
  defer support are unaffected. The permit hook uses `:defer` only in defer
  mode.
- Dependencies: **requires `judge-async-action`** (its action/async/analytic
  machinery is the base; only the parking mechanics change). Feature-detected
  at runtime; unpatched gptel degrades to `prompt` mode. The gptel patch must
  land (and be verified in a live session) before this change archives.
