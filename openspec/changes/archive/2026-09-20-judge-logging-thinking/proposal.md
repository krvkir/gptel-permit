## Why

Judge FAIL verdicts are currently logged as `Judge verdict: FAIL rationale:` with the raw response discarded, so an unparseable response (format violation, backend error page, empty string) is indistinguishable from a genuine UNSAFE in the log. at the same time judge latency is dominated by the model's thinking: a local model asked to "think" before a one-line verdict wastes several seconds per call. Both hurt trust in the judge, and both are cheap to fix before the async work touches this code.

The live verification pass (task 3.2, judge on `glm-5.3-flash:cloud`) then
exposed two more defects in the same code paths: the judge request inherited
the calling session's buffer-local system prompt (the judge model saw the
session's persona and deliberated about which instruction to obey instead of
answering), and the cloud model ignored the thinking-off request field and
interleaved its reasoning with the answer, turning every verdict into a
parse-fail.

## What Changes

- Log the raw judge response (truncated) whenever parsing fails, and add explicit log lines for the timeout and C-g interrupt paths in `gptel-permit--judge-request-sync`.
- Extend `gptel-permit--last-judge-verdict` with failure-class values `parse-fail`, `request-fail`, and `timeout` (distinct from `unsafe`), set together with the raw response in `gptel-permit--last-judge-rationale`, so analytics verdict events can distinguish "judge said no" from "judge broke".
- Add `gptel-permit-judge-request-params` (plist): let-bound as `gptel--request-params` around the judge request so users can pin the judge request body — primarily to disable/minimize model thinking (per-backend snippets documented in README: Anthropic `:thinking (:type "disabled")`, OpenAI `:reasoning_effort "minimal"`, Gemini `:generationConfig (:thinkingConfig (:thinkingBudget 0))`, Ollama `:think :json-false`).
- When `gptel-permit-judge-request-params` is nil, derive a sensible default from the judge backend struct type (disable thinking) instead of leaving the model's default; the derived value is logged once per request for transparency. Document the Gemini shallow-merge caveat (bare judge requests don't need `generationConfig` elsewhere, so clobbering is safe here).
- Send the judge request with `:system nil`: `gptel-request`'s `:system` keyword defaults to the *buffer-local* `gptel-system-prompt` of the calling buffer, so the judge inherited the session's persona. The judge payload now carries no system message; the judge preamble is the only role-setting text.
- Make verdict parsing tolerant of reasoning leaked into the answer: strip `​`/`​` blocks first, then take the verdict from the last line that is exactly SAFE or UNSAFE; responses where SAFE and UNSAFE both appear as standalone lines (an exploratory draft that disagrees with the conclusion) stay unparseable — fail-closed.
- Truncate the raw response stored and logged on parse-fail via `gptel-permit--truncate-arg` (the design specified this; the implementation had skipped it).

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `llm-judge`: failure observability (raw-response logging, failure-class verdict symbols, explicit timeout/quit logging) and request tuning (`gptel-permit-judge-request-params` with per-backend thinking defaults) are new requirements on top of the existing contract. Fail-closed semantics are unchanged.

## Impact

- Code: `gptel-permit-judge.el` (request function, parse function, safe-p condition, new defcustom), README (per-provider snippets, troubleshooting FAIL entries). `gptel-permit-analytics.el` needs **no** code change: its `--judge-fields` passes `gptel-permit--last-judge-verdict` through verbatim, so failure classes reach JSONL automatically; only its README section should document the new symbol set.
- The live-pass fixes (system-prompt isolation, leak-tolerant parsing, raw-response truncation) extend the same two functions; analytics is unaffected (verdict/rationale shapes are unchanged, the rationale on parse-fail is now actually truncated).
- Hook pipeline: none — rule matching behavior is unchanged; every failure path still returns nil (fail-closed). Only the *record* of failures improves.
- Dependencies: this change must be archived **after** `callable-conditions-and-judge` (its `llm-judge` spec delta is the baseline being modified) and `analytics` (its `analytics` spec is the baseline for the failure-class field).
- Groundwork: no async machinery here, but the failure-class symbols and raw-response retention are prerequisites for the async-judge changes (`judge-async-action`, `judge-async-defer`), which will hit the same parse/request paths.
