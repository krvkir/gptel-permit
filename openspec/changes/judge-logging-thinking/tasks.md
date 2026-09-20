## 1. Judge failure observability

- [ ] 1.1 Extend `gptel-permit--judge-request-sync` to signal the failure class to its caller (distinct values for request error / timeout / C-g) and log explicit `Judge timeout after Ns` and `Judge interrupted` lines in the existing `gptel-permit--log` style
- [ ] 1.2 In `gptel-permit-judge-safe-p`, set `gptel-permit--last-judge-verdict` to `parse-fail`/`request-fail`/`timeout` (instead of nil) on the corresponding failure paths, storing the truncated raw response in `gptel-permit--last-judge-rationale`, and log `Judge response unparseable: <truncated raw>` when parse fails on a non-nil response
- [ ] 1.3 Update the docstrings of `gptel-permit--last-judge-verdict` and `gptel-permit--last-judge-rationale` to document all five verdict symbols and the rationale-contains-raw-response-on-failure semantics
- [ ] 1.4 Add ERT tests: parse-fail (garbage response → verdict symbol, log, nil return), timeout class, request-fail class, and that `safe`/`unsafe` paths are unchanged

## 2. Judge request tuning

- [ ] 2.1 Add `gptel-permit-judge-request-params` defcustom (plist, default nil, docstring covering precedence, explicit-`()`-disables-injection, and the Gemini shallow-merge caveat)
- [ ] 2.2 Implement the backend-type derivation (`cl-typecase` over `gptel-anthropic`/`gptel-openai`/`gptel-gemini`/`gptel-ollama` structs → thinking-off plist; nil otherwise), let-binding the effective value as `gptel--request-params` around the judge request, and logging it once per request
- [ ] 2.3 Add ERT tests: user params win over derived defaults, per-backend derivation table, unknown backend → nil, empty list disables injection
- [ ] 2.4 README: judge section gains the per-provider copy-paste snippets and a troubleshooting entry explaining `FAIL` log lines vs failure-class symbols

## 3. Verification

- [ ] 3.1 Byte-compile all gptel-permit files and run the full ERT suite (`make test`); fix regressions
- [ ] 3.2 Manual pass with a live judge: one SAFE, one UNSAFE, one unparseable (force via a mock), one timeout — confirm log lines and (with analytics on) `judge-verdict` values in JSONL

## 4. Live-pass fixes (defects found during task 3.2)

- [X] 4.1 Isolate the judge request from the session: pass `:system nil` to `gptel-request` (no system message; verified with gptel dry-run payload probes), update the request-sync docstring, add a keyword-argument ERT test and an end-to-end payload test with a canary session system prompt
- [X] 4.2 Leak-tolerant verdict parsing: strip `​`/`​` blocks, verdict = last line that is exactly SAFE or UNSAFE, conflicting standalone verdicts unparseable; ERT tests for stripping, leaked deliberation, think-block drafts, conflicts and glued verdicts
- [X] 4.3 Truncate parse-fail raw responses via `gptel-permit--truncate-arg` (rationale variable + log line); ERT test
- [X] 4.4 README (isolation note, leak tolerance, unparseable bullet) and spec-delta MODIFIED requirements; full `make test` (130 passing) + clean byte-compile
- [X] 4.5 GPT-OSS thinking-level derivation (source: docs.ollama.com/capabilities/thinking): the Ollama branch takes the judge model name — a `gpt-oss` base name derives `(:think "low")` (booleans ignored, trace cannot be fully disabled), everything else `(:think :json-false)`; verified on Ollama 0.32.14 that `think: false` is a harmless no-op for non-thinking models and that levels shorten traces on regular thinking models; table tests extended, README/defcustom docstring/spec delta updated
