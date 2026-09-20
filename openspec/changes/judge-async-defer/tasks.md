## 1. gptel patch (~/repos/emacs/gptel, its own commit)

- [ ] 1.1 `gptel--handle-pre-tool`: honor `:defer` in hook results — `(plist-put tool-call :defer t)` and skip other verdict application for that call; add `:fsm fsm` to the hook plist
- [ ] 1.2 `gptel--handle-tool-use`: filter deferred calls out of the tool-use pass (no execution, no pending-calls entry)
- [ ] 1.3 Add `gptel--resolve-tool-call (fsm tool-call verdict)`: merge verdict via the hook merge paths (`:confirm` plist-put; `:args`/`:name` → `gptel--inject-tool-call` + `gptel--merge-plists`; `:block` → error result), clear `:defer`, transition directly to TOOL; no-op guards (not deferred / has `:result` / FSM in ABRT/DONE)
- [ ] 1.4 Write the dated design note (org, gptel repo convention) describing the `:defer` protocol and resolver; verify no patch is needed in `gptel--process-tool-call` (remaining-count already parks the FSM) with a live smoke test
- [ ] 1.5 Manual FSM smoke test in gptel: a test hook that defers then resolves after `sleep-for`; confirm no prompt, no premature LLM round-trip, correct execution after resolution, abort mid-park is clean

## 2. Permit-side defer mode

- [ ] 2.1 Extend `gptel-permit-judge-async` to `(choice (const auto) (const defer) (const prompt) (const nil))`, default `auto`; `t` reads as `prompt`; feature-detect via `(fboundp 'gptel--resolve-tool-call)`; one-time effective-mode log line
- [ ] 2.2 In the judge-action hook path (defer mode): stash `(fsm tool-call rule-index action timer)`, return `(:defer t)`; reuse the async request + watchdog from judge-async-action
- [ ] 2.3 Callback resolution (defer mode): guards (FSM state, buffer live, call lacks `:result`, `:defer` still set) → SAFE: build the paired action's verdict (`sandbox` → adapter-registry args rewrite) and call `gptel--resolve-tool-call`; UNSAFE/failure/timeout: re-scan rules from `rule-index+1`, resolve with the first match's verdict or empty verdict; no-op paths log
- [ ] 2.4 ERT tests with a stubbed resolver and fake tool-call plists: SAFE→allow resolves `(:confirm nil)`, SAFE→sandbox carries rewritten args, UNSAFE→next-rule `ask` verdict applied, no-later-rule→empty verdict, timeout path, abort/dead-buffer/raced no-ops, `auto` mode selection both ways

## 3. Analytics and docs

- [ ] 3.1 Add `judge-latency-ms` to async verdict events (issue timestamp in the stash, arrival in the callback); ERT test for the field
- [ ] 3.2 README: async modes table (nil/prompt/defer/auto), defer-mode behavior (invisible park, fall-through semantics, pack-mates prompt independently), gptel patch requirement + how to detect degradation
- [ ] 3.3 Byte-compile both repos' files, full ERT suite (`make test`), fix regressions
- [ ] 3.4 Manual pass with live model: defer SAFE auto-runs with no prompt ever shown; defer UNSAFE with a following `ask` rule shows the ask prompt; timeout falls through; abort mid-park leaves nothing stuck; unpatched gptel degrades to prompt mode silently
