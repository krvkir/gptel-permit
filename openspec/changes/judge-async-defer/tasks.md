## 1. gptel patch (~/repos/emacs/gptel, its own commit)

- [ ] 1.1 `gptel--handle-pre-tool`: honor `:defer` in hook results — `(plist-put tool-call :defer t)` and skip other verdict application for that call; add `:fsm fsm` to the hook plist
- [ ] 1.2 `gptel--handle-tool-use`: filter deferred calls out of the tool-use pass (no execution, no pending-calls entry)
- [ ] 1.3 Add `gptel--resolve-tool-call (fsm tool-call verdict)`: merge verdict via the hook merge paths (`:confirm` plist-put; `:args`/`:name` → `gptel--inject-tool-call` + `gptel--merge-plists`; `:block` → error result), clear `:defer`, transition directly to TOOL; no-op guards (not deferred / has `:result` / FSM in ABRT/DONE)
- [ ] 1.4 Write the dated design note (org, gptel repo convention) describing the `:defer` protocol and resolver; verify no patch is needed in `gptel--process-tool-call` (remaining-count already parks the FSM) with a live smoke test
- [ ] 1.5 Manual FSM smoke test in gptel: a test hook that defers then resolves after `sleep-for`; confirm no prompt, no premature LLM round-trip, correct execution after resolution, abort mid-park is clean

## 2. Permit-side defer mode

- [ ] 2.1 Extend `gptel-permit-judge-async` to `(choice (const auto) (const defer) (const prompt) (const nil))`, default `auto`; `t` reads as `prompt`; feature-detect via `(fboundp 'gptel--resolve-tool-call)`; one-time effective-mode log line
- [ ] 2.2 In the judge-action hook path (defer mode): stash `(fsm tool-call-identity on-safe on-unsafe timer issued-at)`, return `(:defer t)`; reuse the async request + watchdog from judge-async-action
- [ ] 2.3 Callback resolution (defer mode): guards (FSM state, buffer live, call lacks `:result`, `:defer` still set) → compute the verdict→action mapping's resolution (SAFE → ON-SAFE verdict with sandbox args rewritten via the adapter registry; UNSAFE → ON-UNSAFE verdict with deny carrying the rationale; failure or audit-sampled → `(:confirm t)`) and apply it via `gptel--resolve-tool-call`; no-op paths log
- [ ] 2.4 ERT tests with a stubbed resolver and fake tool-call plists: SAFE→allow resolves `(:confirm nil)`, SAFE→sandbox carries rewritten args, UNSAFE→deny carries the rationale block, UNSAFE→ask surfaces the prompt verdict, failure→ask, sampled→ask, timeout path, abort/dead-buffer/raced no-ops, `auto` mode selection both ways

## 3. Docs and verification

- [ ] 3.1 README: async modes table (nil/prompt/defer/auto), defer-mode behavior (invisible park, per-call resolution, pack-mates prompt independently, ask/failure surfaces the prompt), gptel patch requirement + how to detect degradation
- [ ] 3.2 Byte-compile both repos' files, full ERT suite (`make test`), fix regressions
- [ ] 3.3 Manual pass with live model: defer SAFE auto-runs with no prompt ever shown; defer UNSAFE→deny feeds the rationale with no prompt; defer UNSAFE→ask shows the prompt only at verdict time; timeout surfaces the prompt; abort mid-park leaves nothing stuck; unpatched gptel degrades to prompt mode silently
