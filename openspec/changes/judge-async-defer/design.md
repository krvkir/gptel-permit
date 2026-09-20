## Context

gptel's pre-tool hook protocol is synchronous: `gptel--handle-pre-tool`
(gptel.el:1519) runs each hook over every unresolved tool call and consumes
the returned plist immediately — `:confirm` merged onto the call,
`:args`/`:name` merged into the prompt data and the executing call
(`gptel--inject-tool-call` + `gptel--merge-plists`), `:block`/`:result`
short-circuiting execution. The FSM then leaves TPRE (its handler list ends
with `gptel--fsm-transition` → TOOL) and `gptel--handle-tool-use`
(gptel-request.el) executes or queues each unresolved call — deferred
verdicts simply do not exist.

Two structural facts make a small patch sufficient:

- `gptel--process-tool-call` counts `remaining` as calls without `:result`;
  a deferred call never gets `:result` while parked, so the final FSM
  transition (TOOL → TRET → WAIT, the LLM round-trip) is *naturally*
  suppressed — no change needed there.
- TPRE and TOOL are explicitly re-entrant by design (their docstrings say
  "this function might run many times, so only act on the remaining tool
  calls"), and the tool-use pass filters on `:result`, so an undeferred
  call is picked up cleanly on the next TOOL entry.

`judge-async-action` (implemented first) provides the judge forms, the
verdict→action mapping, the async request + watchdog + stash, and the
analytics events; this change only replaces the parking mechanics.

## Goals / Non-Goals

**Goals:**
- Judge calls park invisibly: no prompt while judging, no user race, no UI
  freeze.
- An upstreamable gptel patch — general (any hook may defer), minimal
  (~3 edit sites + 1 helper), no new FSM states.
- Identical resolution semantics across all modes: the verdict→action
  mapping is mode-independent; only *where* the resolution lands differs.
- Feature detection: unpatched gptel degrades to `prompt` mode.

**Non-Goals:**
- Changing the `prompt`-mode mechanics (both modes coexist behind
  `gptel-permit-judge-async`).
- Making `:defer` available to the condition form
  (`gptel-permit-judge-safe-p` stays synchronous; conditions cannot defer).
- Upstreaming the patch to gptel mainline (out of our repo's scope; the
  patch is prepared upstreamable, delivery is a separate decision).

## Decisions

1. **`:defer` is data on the tool-call plist, not a hook-protocol control
   flow.** The hook returns `(:defer t)` like any verdict; gptel marks the
   call and treats it as "not ready": excluded from `handle-tool-use`'s
   execution *and* its pending-calls prompt. No new FSM states; the FSM
   parks in TOOL because the remaining-count in `gptel--process-tool-call`
   still includes the deferred call.
   *Alternative rejected:* an async-aware hook protocol (hooks returning
   continuations/closures) — needs per-hook re-entry bookkeeping, timeouts,
   and a new hook-runner; strictly more machinery for the same effect.

2. **Resolver merges the verdict, transitions directly to TOOL — not
   TPRE.** `gptel--resolve-tool-call (fsm tool-call verdict)` applies the
   same merge branches as `gptel--handle-pre-tool` (`:confirm` → plist-put;
   `:args`/`:name` → inject + merge-plists; `:block` → error+result), clears
   `:defer`, and calls `(gptel--fsm-transition fsm 'TOOL)`.
   *Why not re-enter TPRE:* re-running pre-tool hooks on the resolved call
   would (a) re-run rule matching against *rewritten* (sandbox-wrapped)
   args — violating the spec invariant "rules, the judge, and validation
   always see the original unwrapped command" — and (b) require
   re-entrancy markers in every hook to avoid judge loops. TOOL's handlers
   (`gptel--update-tool-call`, `gptel--handle-tool-use`,
   `gptel--update-tool-ask`) then execute the call or show the prompt for
   it, exactly as they would have right after the first TPRE pass.

3. **The hook plist gains `:fsm`.** Permit's callback needs the FSM to call
   the resolver; gptel passes it in `hook-func-args`
   (`(:buffer … :backend … :model … :fsm fsm)`). Additive; hooks that
   ignore it are unaffected. Feature detection:
   `(fboundp 'gptel--resolve-tool-call)`.

4. **Resolution is the plain verdict→action mapping — no rule re-scan.**
   The judge rule matched and owns the call in every mode; the callback
   resolves with the mapping's verdict: SAFE → ON-SAFE (allow →
   `(:confirm nil)`; sandbox → `(:confirm nil :args REWRITTEN)` via the
   adapter registry; ask → `(:confirm t)`), UNSAFE → ON-UNSAFE (deny →
   `(:block …)` with the rationale), failure → `(:confirm t)`, audit-sampled
   → `(:confirm t)`. An `ask` or failure resolution surfaces the prompt at
   that point — the prompt appears exactly when a human is needed.
   *This replaces the earlier design's rule-index continuation:* with the
   two-slot judge grammar, the ON-UNSAFE slot already expresses the
   negative resolution, so re-scanning later rules would contradict the
   action-form semantics ("the judge sits in the action part; it does not
   determine rule applicability"). The stash needs no rule index, and the
   callback is a pure function of `(verdict on-safe on-unsafe)`.

5. **Pack gating is unnecessary in defer mode.** Deferred calls never reach
   the pending-calls list, so a deferred call cannot smuggle a pack-mate
   into a programmatic resolution: each deferred call is resolved
   *individually* by its own verdict, and non-judged calls in the same
   round prompt/run independently of it. The all-or-nothing uniformity
   gating stays in `prompt` mode only (it exists because gptel's prompt is
   pack-granular).
   *Consequence for multi-call rounds:* some calls may prompt while a
   sibling call is deferred — the prompt shows only the non-deferred
   calls, and the deferred one executes when its verdict lands, even while
   the user still stares at the prompt for the others. `handle-tool-use`'s
   re-entrancy ("only act on the remaining") makes this safe: the deferred
   call joins the next TOOL pass via the resolver.

6. **Watchdog resolves, not aborts.** The per-stash timer
   (`gptel-permit-judge-timeout`) calls the same resolution path with the
   `timeout` failure class (→ the manual-confirmation verdict, surfacing
   the prompt). The gptel request itself is left alone (abort machinery is
   heavier than needed; a stray late response hits the already-resolved
   guard and is discarded + logged).

7. **Mode selection: `auto` default.** `gptel-permit-judge-async` becomes
   `(choice (const auto) (const defer) (const prompt) (const nil))`,
   default `auto`: `defer` when `(fboundp 'gptel--resolve-tool-call)`,
   else `prompt`. Explicit values win; `nil` keeps sync; the old boolean
   `t` reads as `prompt` for compatibility. A one-time log line announces
   the resolved mode at first judge use.

## Risks / Trade-offs

- [Upstream gptel drift: the patch touches three internal functions] →
  Feature detection degrades gracefully to `prompt` mode; patch is small
  enough to rebase quickly; pinned in the user's local gptel checkout
  (a fork) until upstreamed.
- [Stale stash: user aborts (FSM → ABRT) or kills the buffer while parked]
  → Resolver guards: FSM state not ABRT/DONE, buffer live, tool-call
  lacking `:result`, `:defer` still set; each failure no-ops with a log
  line. `gptel-abort` during a park is identical to aborting during a
  normal prompt today.
- [Deferring a call while its pack-mates prompt may surprise users
  (prompt shows 2 of 3 calls; the third runs "by itself" later)] → The
  status line already shows per-tool activity; defer mode's premise is
  that judge-gated calls are trusted auto-run calls; documented in README.
- [Callback runs from a timer/process context] → All resolution happens on
  the main thread (gptel's callback machinery and Emacs timers are
  main-thread); `with-current-buffer` into the request buffer as in
  prompt mode — no threading concerns.

## Migration Plan

1. Land and verify the gptel patch in the local checkout (its own commit,
   dated org note in the gptel repo, manual FSM smoke test).
2. Implement permit-side defer mode behind `gptel-permit-judge-async =
   'defer`; keep `prompt` and sync modes intact.
3. Flip the default to `auto`; existing `t`/`nil` users of the boolean are
   unaffected (`t` reads as `prompt`).
Rollback: set the defcustom to `prompt`; the gptel patch is inert without
permit using `:defer`.

## Open Questions

- Upstream PR to gptel: deliver after both async changes settle (the
  `:defer` key plus `:fsm` in the hook plist are the only API surface).
- `gptel-agent`'s tool loop: it defines its own FSM/loop; defer mode is
  `gptel-send`-only until audited there — `auto` mode does not claim
  agent support (verify during implementation; degrade to prompt mode if
  the agent loop bypasses `gptel--handle-pre-tool`).
