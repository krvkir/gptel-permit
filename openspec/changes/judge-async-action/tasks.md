## 1. Judge action dispatch (shared verdict mapping)

- [x] 1.1 Extend rule-action dispatch in `gptel-permit.el` per D1: a cons action dispatches on its car and the handler is called with the action's cdr as a third argument; bare symbols keep the 2-arity call; add the core-owned `gptel-permit--programmatic-call` defvar (D4, generic docstring, no add-on names); extend the `:action` customize type for the judge forms
- [x] 1.2 Implement `gptel-permit--judge-action-verdict (verdict on-safe on-unsafe id tool-call)` — the single verdict→resolution mapping: SAFE → ON-SAFE action verdict, UNSAFE → ON-UNSAFE action verdict (both dispatched through `gptel-permit-action-handlers` with the same id/tool-call), failure class → `(:confirm t)`; `deny` resolutions embed the judge rationale; the judge prompts on the call's full argument set (D2)
- [x] 1.3 ERT tests: grammar parsing (bare/1-arg/2-arg forms, defaults, malformed fail-closed), SAFE applies ON-SAFE, UNSAFE applies ON-UNSAFE (ask and deny), failure maps to ask, `(judge sandbox deny)` SAFE wraps via the action-registry sandbox handler (sync + async), `(judge allow sandbox)` UNSAFE wraps (async), malformed-fail-closed through the handler, engine-level cons-dispatch (D1, in `gptel-permit-rule-engine-hooks-test.el`), no fall-through to later rules on UNSAFE — all in `tests/gptel-permit-judge-action-test.el`, 184/184 green

## 2. Async resolution machinery

- [x] 2.1 Add `gptel-permit-judge-async` defcustom (default t) with docstring covering both modes and the prompt-while-judging tradeoff
- [x] 2.2 Implement the buffer-local stash `(tool identity, on-safe, on-unsafe, timer, issued-at)`, the non-blocking judge request, and the per-entry watchdog at `gptel-permit-judge-timeout` (callback cancels the timer; watchdog resolves as `timeout`; late responses discarded via the resolved guard)
- [x] 2.3 Implement the callback resolution: `with-current-buffer` into the stash's buffer; set the judge state vars; parse verdict; compute resolutions per mapping; consult `gptel-permit-veto-functions` with the would-be verdict before applying it (D3 — a veto forces the manual resolution); locate the pending-confirmation overlay by tool-call identity; apply only for all-judge-gated, uniform packs — all accept-class → rewrite args via the action-registry sandbox handler, `gptel--accept-tool-calls` under a `gptel-permit--programmatic-call` binding (D4); all deny → `gptel-permit--judge-reject-pending` with rationale-bearing reasons + cleanup, also under the flag; anything else → log, leave the prompt.  The analytics pending-entry pop with pre-rewrite args landed in 3.2, the transient resolution messages in 4.1
- [x] 2.4 Implement the judging indicator: stacked zero-width overlay with `before-string` at the prompt overlay start when a stash entry is pending; delete on resolution (accept/reject/ask/timeout/user action)
- [x] 2.5 Liveness/race guards: buffer-dead no-op, overlay-gone no-op, already-`:result`ed call no-op (user acted first), stray late response after watchdog no-op — each with a log line
- [x] 2.6 ERT tests (stub judge request capturing the callback; overlay + real minimal tool structs): SAFE auto-accept rewrites args for sandbox, UNSAFE→ask stays on prompt, UNSAFE→deny rejects the pack with the rationale in the result, timeout leaves prompt and late response discarded, user-race no-op, mixed/uniform pack gating (mixture never auto-resolves), indicator appears and is removed — all in `tests/gptel-permit-judge-action-test.el`, 178/178 green

## 3. Analytics integration

- [x] 3.1 Add the `judge-verdict` event type (verdict incl. failure classes, rationale, judged arg, latency; correlated by the original tool-call id), emitted from the callback in the verdict-owning buffer
- [x] 3.2 Record programmatic resolutions as `decision` events with choices `auto-allow` (auto-accept) and `deny` (auto-reject); pop pending confirmations with pre-rewrite args per the sandbox-backend-registry analytics requirement; make the decision-capture advice skip calls made under a `gptel-permit--programmatic-call` binding (D4 — no double-capture as user decisions)
- [x] 3.3 Extend audit sampling to judge-gated async calls via the resolution-time veto consult (D3): sampled → emit `audit`, run the judge, log the verdict, force the manual-confirmation resolution regardless of verdict; never programmatically resolve a sampled call
- [x] 3.4 Serialize list-form judge actions in `gptel-permit-analytics--action-string` (e.g. `(judge sandbox deny)` → "judge:sandbox/deny")
- [x] 3.5 ERT tests: async SAFE chain event sequence shares one id; UNSAFE-then-manual-accept records both judge-verdict and the user decision with correct wait-ms; sampled call emits audit + judge-verdict and never auto-resolves

## 4. UX and docs

- [x] 4.1 Transient messages: judge issue note, programmatic resolution notes (auto-accept / auto-reject with reason), failure note naming the class; no `message` spam regressions in sync mode
- [x] 4.2 README: judge action section — DSL grammar with all three forms, verdict semantics table (SAFE/UNSAFE/failure), sync/async modes, pack uniformity gating, sampling behavior, prompt-while-judging tradeoff and the pointer to the optional defer mechanics
- [x] 4.3 Byte-compile, full ERT suite (`make test`), fix regressions
- [ ] 4.4 Manual pass with a live model: async SAFE auto-accept observed end-to-end (indicator shows, prompt vanishes on accept), UNSAFE→deny rejects with rationale visible to the LLM, UNSAFE→ask stays, timeout leaves prompt, `(judge allow sandbox)` wraps an UNSAFE call (unit-covered by `gptel-permit-judge-async-unsafe-sandbox-wraps`)
