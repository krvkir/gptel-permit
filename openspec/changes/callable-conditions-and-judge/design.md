# Design: callable-conditions-and-judge

## Context
gptel-permit registers two hooks on `gptel-pre-tool-call-functions`
(synchronously called by `gptel--handle-pre-tool`): `--validate-args` then
`--apply-rules`. Rules are data plists; `--match-rule-p` currently
dispatches condition cdrs through an inline cond over four hardcoded
keywords. The hook plist provides `:name :args :buffer :backend :model`
(`:buffer` is a buffer NAME string; `:backend` is the backend struct).
gptel demotes hook errors to nil and treats nil as "no opinion", so hook
code must never let an error escape into an implicit allow.

## Goals / Non-Goals
Goals: extensible pure checkers users can register; an LLM judge condition
for `execute`-group grey zone; fail-closed everywhere; rationale retention
for later audit. Non-goals: judge as a 3-way action (deny/ask/allow) —
locked decision: judge is a boolean condition and never blocks; async
judging; blocking-hook-free design (impossible: hooks are synchronous).

## Decisions
- **Callable cdr in `:conditions`** (not a separate checker registry):
  the rule list is already the ordered, precedence-aware pipeline;
  conditions stay pure/serializable, custom logic plugs in as a function.
  Dispatch order: stringp → regexp; keywordp → `gptel-permit--condition-predicates`
  alist lookup; functionp → funcall with `(value tool-call)`.
- **Judge as a condition** (`gptel-permit-judge-safe-p`), placed as the last
  condition of a rule whose action then fires. Rationale: conditions are
  boolean, sequential, short-circuiting; a blocking side-effecting judge is
  only sound as the last gate. Deny stays deterministic via `:action deny`
  rules listed before the judge rule (Embrace The Red showed per-call
  classifiers are blind to multi-hop chains — they must not own denies).
- **Blocking request**: `gptel-request` with let-bound `gptel-backend`/
  `gptel-model` (gptel-quick pattern), tools/context/stream off;
  `accept-process-output` spin loop with `gptel-permit-judge-timeout`;
  `condition-case` + `with-local-quit`. A bare `gptel-request` never
  re-enters the pre-tool hooks (they only exist on the `gptel-send` FSM),
  so the judge is safe from recursion.
- **Verdict contract**: first non-empty line SAFE or UNSAFE; following
  line(s) are a one-line rationale stored buffer-locally in
  `gptel-permit--last-judge-rationale` (consumed by the analytics change).
- **History opt-in**: `gptel-permit-judge-history-entries` default 0.
  When > 0, fetch via `(with-current-buffer (get-buffer <:buffer name>)
  (gptel--parse-buffer ...))`, last N entries, each truncated. History is
  injectable content, so default-off; the blast-radius question needs the
  command, not the log. Name ambiguity (two buffers, same name) is a
  best-effort risk, cosmetic in effect.
- **Fail closed**: unconfigured backend, request error, timeout, unparseable
  output, C-g — all return nil. Nil means "rule doesn't match", which falls
  through to the next rule, normally `ask`. The judge never auto-allows on
  failure and never emits `:block`.

## Risks / Trade-offs
- UI freeze up to timeout while judging → keep judge model small/local,
  echo-area progress message, `with-local-quit` for C-g.
- Hook errors demoted to nil by gptel → outer `condition-case` returns nil
  (defer), never t; `--apply-rules` also gains a `condition-case` returning
  `(:confirm t)` on unexpected error.
- Judge rationale retention is in-memory only until the analytics change
  wires it into JSONL events; documented as such.

## Migration Plan
Ship `gptel-permit-judge.el`, `(require 'gptel-permit-judge)` optional.
Existing rules unchanged. Rollback: don't require the new file.

## Open Questions
None blocking. srt-based sandbox composition lives in the sandbox-action
change.
