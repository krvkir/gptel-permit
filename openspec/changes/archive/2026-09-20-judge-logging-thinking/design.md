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

The task 3.2 live pass (judge on `glm-5.3-flash:cloud`, an Ollama *cloud*
model) then exposed two more defects on these paths: the judge request
inherited the calling session's buffer-local system prompt — `gptel-request`'s
`:system` keyword defaults to it and every backend prepends it as the system
message — so the judge model saw the session's persona and deliberated out
loud about which instruction to obey; and the cloud model ignored the derived
`think: false` field and interleaved its reasoning inline in the answer
content (gptel-ollama separates only the server-provided `message.thinking`
channel), so every verdict parse-failed. A third, smaller defect surfaced at
the same time: parse-fail rationale and log lines carried the raw response
untruncated, contradicting the docstrings and this design.

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
   The Ollama branch is model-sensitive: per
   docs.ollama.com/capabilities/thinking, GPT-OSS models ignore boolean
   `think` and accept only levels (`low`/`medium`/`high`, trace cannot be
   fully disabled), so a judge model whose base name is `gpt-oss` derives
   `(:think "low")`. Everything else derives `(:think :json-false)`, verified
   on Ollama 0.32.14 to be a harmless no-op for models without a thinking
   capability (thinking-capable qwen3.5:4b emits an empty trace with
   `think: false`; non-thinking qwen2.5:7b returns normally); levels are
   accepted by regular thinking models too (`think: "low"` shortens the
   trace versus the default).

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

7. **Judge requests carry no system message (`:system nil`).**
   `gptel-request`'s `:system` keyword defaults to the buffer-local
   `gptel-system-prompt` of the calling buffer, and gptel's prompt-buffer
   copy reads that value via `buffer-local-value`. A dynamic `let` shadows
   the calling buffer's local binding for that read (verified empirically:
   `(let ((v "LET")) (buffer-local-value v buf))` yields "LET"), so the
   keyword flows through the copy into every backend's
   `(when gptel-system-prompt …)` guard. Verified end-to-end with gptel
   dry-run payload probes in the live session buffer: the control reproduces
   the leaked system message; `:system nil` yields a payload with no system
   message and the derived `:think :json-false` still merged. The judge
   preamble in the user message is the only role-setting text.
   *Why:* one keyword argument, no restructuring; gptel documents nil as
   "no system prompt".

8. **Leak-tolerant verdict parsing, fail-closed.** Request-side thinking
   suppression cannot be relied on (cloud models ignore `think: false`), so
   the parser strips `​`/`​` blocks and reads the
   verdict from the last line whose entire trimmed text is exactly SAFE or
   UNSAFE; the rationale is the text after that line. Responses with
   standalone SAFE *and* UNSAFE lines — an exploratory draft disagreeing
   with the conclusion — are unparseable rather than guessed.
   *Why last standalone line:* thinking models draft and explore before
   concluding, so the final standalone verdict is their answer; the observed
   leak contained a draft SAFE verdict and a final SAFE answer, and the
   strict first-line parser turned it into a parse-fail. *Why
   conflict-reject:* a leaked exploratory UNSAFE must not be silently
   upgraded to a safe verdict (and vice versa); rejecting keeps every
   ambiguous output fail-closed. *Limitation documented:* a verdict word
   glued mid-line (a server concatenating thinking and answer without a
   separator) does not count and parse-fails — the error direction is
   toward ask, never a new allow path.

9. **Parse-fail raw responses are truncated** via
   `gptel-permit--truncate-arg` in both `gptel-permit--last-judge-rationale`
   and the log line — this design already required it; the implementation
   had omitted it.

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
  default. In Emacs Lisp an empty plist is indistinguishable from nil, so
  there is no "empty" state that suppresses injection; set a non-nil plist
  re-enabling what you want (e.g. `(:think t)`).
- [Relaxed parsing could latch onto a leaked draft verdict] → conflicting
  standalone SAFE and UNSAFE lines are rejected outright; the residual case
  (a single draft verdict whose value differs from a glued final answer)
  requires both a mid-reasoning mind change and server-side thinking/content
  concatenation, and is accepted because the judge is a friction-reducer
  behind deterministic deny rules, not a security boundary.
- [Judge sees no system prompt at all] → intentional; the judge preamble in
  the user message defines its role, and removing the session persona is the
  point. Users needing a judge-level directive have
  `gptel-permit-judge-policy`.

## Migration Plan

Pure additive; no config migration. Existing JSONL analytics files simply
start containing the new `judge-verdict` values when failures occur. Rollback
is reverting the commit — no state to unwind.

## Open Questions

- (None blocking. Exact truncation length for raw responses follows
  `gptel-permit--truncate-arg`; revisit if judge responses routinely exceed it.)
