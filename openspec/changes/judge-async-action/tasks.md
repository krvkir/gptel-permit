## 1. Judge action dispatch (shared verdict mapping)

- [ ] 1.1 Extend rule-action dispatch in `gptel-permit.el` to recognize the judge forms (`judge`, `(judge A)`, `(judge A B)`); validate grammar at evaluation entry — malformed forms log a warning and act as `ask`; extend the `:action` customize type
- [ ] 1.2 Implement `gptel-permit--judge-action-verdict (verdict on-safe on-unsafe)` — the single verdict→resolution mapping: SAFE → ON-SAFE action verdict (sandbox via the adapter registry), UNSAFE → ON-UNSAFE action verdict, failure class → `(:confirm t)`; `deny` resolutions embed the judge rationale
- [ ] 1.3 ERT tests: grammar parsing (bare/1-arg/2-arg forms, defaults, malformed fail-closed), SAFE applies ON-SAFE, UNSAFE applies ON-UNSAFE (ask and deny), failure maps to ask, `(judge sandbox deny)` SAFE wraps via adapter, `(judge allow sandbox)` UNSAFE wraps via adapter, no fall-through to later rules on UNSAFE

## 2. Async resolution machinery

- [ ] 2.1 Add `gptel-permit-judge-async` defcustom (default t) with docstring covering both modes and the prompt-while-judging tradeoff
- [ ] 2.2 Implement the buffer-local stash `(tool identity, on-safe, on-unsafe, timer, issued-at)`, the non-blocking judge request, and the per-entry watchdog at `gptel-permit-judge-timeout` (callback cancels the timer; watchdog resolves as `timeout`; late responses discarded via the resolved guard)
- [ ] 2.3 Implement the callback resolution: `with-current-buffer` into the stash's buffer; set the judge state vars; parse verdict; compute resolutions per mapping; locate the pending-confirmation overlay by tool-call identity; apply only for all-judge-gated, uniform packs — all accept-class → rewrite args via the adapter registry, pop the analytics pending entry with pre-rewrite args, `gptel--accept-tool-calls`; all deny → `gptel-permit--reject-pending` with rationale-bearing reasons + cleanup; anything else → log + transient message, leave the prompt
- [ ] 2.4 Implement the judging indicator: stacked zero-width overlay with `before-string` at the prompt overlay start when a stash entry is pending; delete on resolution (accept/reject/ask/timeout/user action)
- [ ] 2.5 Liveness/race guards: buffer-dead no-op, overlay-gone no-op, already-`:result`ed call no-op (user acted first), stray late response after watchdog no-op — each with a log line
- [ ] 2.6 ERT tests (stub judge request capturing the callback; fake overlay + triples): SAFE auto-accept rewrites args for sandbox, UNSAFE→ask stays on prompt, UNSAFE→deny rejects the pack with the rationale in the result, timeout leaves prompt and late response discarded, user-race no-op, mixed/uniform pack gating (mixture never auto-resolves), indicator appears and is removed

## 3. Analytics integration

- [ ] 3.1 Add the `judge-verdict` event type (verdict incl. failure classes, rationale, judged arg, latency; correlated by the original tool-call id), emitted from the callback in the verdict-owning buffer
- [ ] 3.2 Record programmatic resolutions as `decision` events with choices `auto-allow` (auto-accept) and `deny` (auto-reject); pop pending confirmations with pre-rewrite args per the sandbox-backend-registry analytics requirement
- [ ] 3.3 Extend audit sampling to judge-gated async calls: sampled → emit `audit`, run the judge, log the verdict, force the manual-confirmation resolution regardless of verdict; never programmatically resolve a sampled call
- [ ] 3.4 Serialize list-form judge actions in `gptel-permit-analytics--action-string` (e.g. `(judge sandbox deny)` → "judge:sandbox/deny")
- [ ] 3.5 ERT tests: async SAFE chain event sequence shares one id; UNSAFE-then-manual-accept records both judge-verdict and the user decision with correct wait-ms; sampled call emits audit + judge-verdict and never auto-resolves

## 4. UX and docs

- [ ] 4.1 Transient messages: judge issue note, programmatic resolution notes (auto-accept / auto-reject with reason), failure note naming the class; no `message` spam regressions in sync mode
- [ ] 4.2 README: judge action section — DSL grammar with all three forms, verdict semantics table (SAFE/UNSAFE/failure), sync/async modes, pack uniformity gating, sampling behavior, prompt-while-judging tradeoff and the pointer to the optional defer mechanics
- [ ] 4.3 Byte-compile, full ERT suite (`make test`), fix regressions
- [ ] 4.4 Manual pass with a live model: async SAFE auto-accept observed end-to-end (indicator shows, prompt vanishes on accept), UNSAFE→deny rejects with rationale visible to the LLM, UNSAFE→ask stays, timeout leaves prompt, `(judge allow sandbox)` wraps an UNSAFE call
