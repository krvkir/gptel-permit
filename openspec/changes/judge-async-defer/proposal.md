## Why

`judge-async-action` meets the primary async goal — other buffers stay
fully usable — but parks judged calls on the confirmation prompt while
judging: the prompt flashes, the user can race the judge, and an
`ask`-resolution call shows a prompt that could have been avoided. This
change is the optional polish: gptel has no deferred-verdict hook
mechanism — a hook must return its verdict synchronously — so we add one:
a small, upstreamable patch to gptel (~3 edit sites plus a resolver
helper) that lets a pre-tool hook mark a call as pending-resumption, keeps
the FSM parked invisibly until the verdict arrives, and resolves the call
with the merged verdict. With it, judging is asynchronous *and* invisible:
no prompt, no race.

**Status: optional.** Land only if the prompt flash proves annoying in
practice after `judge-async-action` has been used for a while. Nothing in
the rule DSL or the analytics depends on this change; it is a pure parking
mechanics swap behind the same `gptel-permit-judge-async` option.

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
     reach the resolver; feature detection via the resolver's presence.
  - No patch to `gptel--process-tool-call` is needed: the remaining-count
    (`(not (plist-get call :result))`) already includes deferred calls, so
    the FSM naturally parks in TOOL while a deferred call is unresolved.
  - The patch is documented in the gptel repo as a dated design note
    (that repo's convention).
- **permit side**: `gptel-permit-judge-async` gains the values `defer` and
  `auto`. In defer mode, the judge-action hook stashes
  `(fsm tool-call-identity on-safe on-unsafe timer)` — the same
  verdict→action mapping context as prompt mode — fires the async judge
  request, and returns `(:defer t)`. The callback resolves the call
  individually through `gptel--resolve-tool-call` with the mapping's
  verdict:
  - SAFE → the ON-SAFE action's verdict (`sandbox` resolves with args
    rewritten through the adapter registry);
  - UNSAFE → the ON-UNSAFE action's verdict (`deny` feeds the
    rationale-bearing reason; `ask` surfaces the prompt at that point);
  - failure or audit-sampled call → the manual-confirmation verdict (the
    prompt appears exactly when a human is needed).
  No rule re-scan happens on any path: the matched judge rule owns the
  call, identically to sync and prompt modes — the grammar's ON-UNSAFE
  slot already expresses the negative resolution, so the earlier
  design's rule-index continuation machinery is unnecessary.
- **Mode default**: `gptel-permit-judge-async` becomes `auto` — `defer`
  when the patched gptel is detected, else `prompt` (the
  `judge-async-action` mechanics), else configurable `nil` (sync).
  `prompt` remains available as an explicit choice; the old `t` value
  reads as `prompt`.

## Capabilities

### New Capabilities
- `tool-call-defer`: the deferred pre-tool-verdict protocol — the `:defer`
  hook contract, the parked-while-unresolved invariant (no execution, no
  prompt, no partial LLM round-trips), and the resolver semantics. Written
  as a consumer-side contract (gptel-permit's expectations of the gptel
  patch).

### Modified Capabilities
- `llm-judge`: the async resolution requirement gains the defer parking
  mode — invisible park instead of prompt-park, per-call callback
  resolution via the resolver, with the same verdict→action mapping and
  fail-closed rules.
- `analytics`: no new requirements — the judge-verdict event (with
  latency) and the programmatic decision choices from `judge-async-action`
  already cover defer-mode events; a defer-mode auto-accept records
  `auto-allow` exactly as prompt mode does.

## Impact

- Code: gptel.el (the patch hunks; upstreamable), gptel-permit.el (defer
  verdict emission, stash gains the FSM), gptel-permit-judge.el (defer-mode
  callback), README (mode table).
- Hook pipeline: one new hook-result key (`:defer`), additive; hooks without
  defer support are unaffected. The permit hook uses `:defer` only in defer
  mode.
- Dependencies: **requires `judge-async-action`** (its action/async/
  analytic machinery is the base; only the parking mechanics change).
  Feature-detected at runtime; unpatched gptel degrades to `prompt` mode.
  The gptel patch must land (and be verified in a live session) before
  this change archives.
