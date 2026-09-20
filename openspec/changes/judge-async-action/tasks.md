## 1. Judge action dispatch (sync path first)

- [ ] 1.1 Extend rule-action dispatch in `gptel-permit.el` to recognize cons actions `(judge . ACTION)` (ACTION ∈ allow/sandbox); malformed pairs log a warning and act as `ask`
- [ ] 1.2 Implement the shared verdict→action mapping: sync mode evaluates the judge (blocking request), SAFE → `allow`/`sandbox` verdict (sandbox goes through the adapter registry), UNSAFE/failure → continue the rule scan from the next rule
- [ ] 1.3 ERT tests: SAFE applies action, UNSAFE falls through to later rules, malformed pair fail-closed, sandbox judge wraps via adapter

## 2. Async resolution machinery

- [ ] 2.1 Add `gptel-permit-judge-async` defcustom (default t) with docstring covering both modes and the prompt-while-judging tradeoff
- [ ] 2.2 Implement the stash (buffer, tool-call identity, action, verdict slot, timer), the non-blocking `gptel-request` issue, and the per-entry watchdog at `gptel-permit-judge-timeout` (callback cancels the timer; watchdog resolves as `timeout`; late responses discarded via the resolved guard)
- [ ] 2.3 Implement the callback resolution: `with-current-buffer` into the stash's buffer; set the judge state vars; parse verdict; SAFE → record verdict per call; when every pending call of the pack is judge-gated SAFE → rewrite args via the adapter registry (for `(judge . sandbox)`), pop the analytics pending entry with pre-rewrite args, `gptel--accept-tool-calls` with modified triples; UNSAFE/failure/timeout → log + transient message, leave the prompt
- [ ] 2.4 Liveness/race guards: buffer-dead no-op, overlay-gone no-op, already-` :result`ed call no-op (user acted first), stray late response after watchdog no-op — each with a log line
- [ ] 2.5 ERT tests (stub `gptel-request` capturing the callback; fake overlay + triples): SAFE auto-accept rewrites args for sandbox, UNSAFE leaves prompt, timeout watchdog fires and late response discarded, user-race no-op, mixed pack never accepts (gating), all-SAFE pack accepts once

## 3. Analytics integration

- [ ] 3.1 Add the `judge-verdict` event type (verdict + rationale + judged arg, correlated by the original tool-call id), emitted from the callback in the verdict-owning buffer
- [ ] 3.2 Record programmatic auto-accepts as `decision` events with choice `auto-allow` (distinct from user `allow`); pop pending confirmations with pre-rewrite args per the sandbox-backend-registry analytics requirement
- [ ] 3.3 ERT tests: async SAFE chain event sequence shares one id; UNSAFE-then-manual-accept records both judge-verdict and the user decision with correct wait-ms

## 4. UX and docs

- [ ] 4.1 Transient messages: "judging <tool> call…" on async issue, judge auto-accept note, UNSAFE/failure note naming the reason; ensure no `message` spam in sync mode regressions
- [ ] 4.2 README: judge action section — DSL form, sync/async modes, pack gating semantics, prompt-while-judging tradeoff and the pointer to the upcoming defer mechanics
- [ ] 4.3 Byte-compile, full ERT suite (`make test`), fix regressions
- [ ] 4.4 Manual pass with a live model: async SAFE auto-accept observed end-to-end (prompt appears, vanishes on SAFE), UNSAFE stays on prompt, timeout leaves prompt, sandbox judge wraps before acceptance
