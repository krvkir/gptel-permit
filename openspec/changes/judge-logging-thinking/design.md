## Context

The judge (`gptel-permit-judge.el`) issues a synchronous `gptel-request` to a
small model and parses `SAFE`/`UNSAFE` from the first line
(`gptel-permit--judge-parse-verdict` returns nil on anything else). Today every
non-SAFE outcome collapses into one log line, `Judge verdict: FAIL rationale: …`,
and the raw response is dropped. Separately, judge latency is dominated by the
model's default thinking/reasoning effort; gptel has no `gptel-request` keyword
for it, but every backend merges the dynamic variable `gptel--request-params`
into the request body (precedence: request defaults < `gptel--request-params` <
backend `:request-params` < model `:request-params`), so let-binding it around
the judge request reaches all four built-in backends.

This change is deliberately synchronous: it only fixes observability and
latency. The async-judge changes (`judge-async-action`, `judge-async-defer`)
reuse these failure classes and raw-response retention, so this lands first.

## Goals / Non-Goals

**Goals:**
- Make every judge failure diagnosable from `gptel-permit--log` output alone
  (was it UNSAFE, a format violation, an HTTP error, or a timeout?).
- Give analytics a machine-readable failure class via the existing
  `gptel-permit--last-judge-verdict` variable (no new event types).
- Let the user pin the judge request body per backend, and by default disable
  model thinking for judge requests to cut per-call latency.

**Non-Goals:**
- Asynchronous judging (later changes).
- Changing the verdict contract, prompt shape, or fail-closed semantics.
- Streaming, retry, or model fallback logic.

## Decisions

1. **Failure classes as new verdict symbols, not a separate field.**
   `gptel-permit--last-judge-verdict` currently holds `safe`/`unsafe`. We add
   `parse-fail`, `request-fail`, `timeout` and keep the raw (truncated) response
   in `gptel-permit--last-judge-rationale` for that call.
   *Why:* analytics' `--judge-fields` already serializes the variable verbatim
   (`judge-verdict` field), so JSONL consumers get the classes with zero
   analytics code change. *Alternative rejected:* a new
   `gptel-permit--last-judge-failure` variable — more state to reset in
   `gptel-permit--reset-judge-state` and invisible to existing analytics data.

2. **Raw response retention in the rationale slot.** On failure classes the
   rationale holds the truncated raw response (not an actual rationale — it is
   a response the judge never produced). Docstrings state this.
   *Why:* one audit path for all judge output; the log line and the analytics
   event then agree.

3. **`gptel-permit-judge-request-params` is a plist, let-bound as
   `gptel--request-params` around the whole judge request call.**
   *Why:* gptel merges this variable into every backend's request body; it is
   the documented injection point and it beats model-level `:request-params`
   customizations without requiring the user to duplicate backend/model config.
   *Alternative rejected:* a thinking-specific defcustom per backend family —
   combinatorial explosion, and users may want to pin other fields (e.g.
   temperature) anyway.

4. **Thinking defaults derived from backend struct type when the defcustom is
   nil.** A small `pcase`/`cl-typecase` over the backend object
   (`gptel-anthropic` → `:thinking (:type "disabled")`, `gptel-openai` →
   `:reasoning_effort "minimal"`, `gptel-gemini` → `:generationConfig
   (:thinkingConfig (:thinkingBudget 0))`, `gptel-ollama` → `:think
   :json-false`, others → nil) supplies the let-bound params.
   *Why:* users get fast judges by default; the derived plist is logged (once
   per request) so behavior is transparent. Only the four built-in backend
   structs are recognized — third-party backends get nil (no injection) rather
   than a guess.

5. **Gemini shallow-merge caveat accepted.** gptel's `:request-params` merge is
   shallow, so a plist with `:generationConfig` clobbers any backend-level
   `generationConfig`. The judge request is bare (no other generation config
   needed), so this is safe; documented in the defcustom docstring.

6. **Explicit failure logging at the source.** `--judge-request-sync` logs
   `Judge request failed: …` (already), plus new `Judge timeout after Ns` and
   `Judge interrupted` (C-g) lines; `judge-safe-p` logs
   `Judge response unparseable: <raw truncated>` when parse returns nil on a
   non-nil response. All lines go through `gptel-permit--log` (respects
   `gptel-permit-log-enabled`), not `message`.

## Risks / Trade-offs

- [Failure-class symbols leak into analytics JSONL that consumers may compare
  against `safe`/`unsafe`] → Document the full symbol set in the analytics
  README section; the analytics spec delta names all five values explicitly.
- [Truncated raw responses could contain secrets from the model's own
  reasoning] → Reuse `gptel-permit--truncate-arg` bounds (same truncation the
  judge prompt already applies to arguments); no additional retention window
  (buffer-local, reset per call by `gptel-permit--reset-judge-state`).
- [Derived thinking params fight a user who *wants* thinking judges] →
  `gptel-permit-judge-request-params` non-nil always wins over the derived
  default; setting it to an explicit `()` disables injection entirely.

## Migration Plan

Pure additive; no config migration. Existing JSONL analytics files simply
start containing the new `judge-verdict` values when failures occur. Rollback
is reverting the commit — no state to unwind.

## Open Questions

- (None blocking. Exact truncation length for raw responses follows
  `gptel-permit--truncate-arg`; revisit if judge responses routinely exceed it.)
