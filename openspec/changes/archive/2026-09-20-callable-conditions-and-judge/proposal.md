# Proposal: callable-conditions-and-judge

## Why
Rule conditions are hardcoded to four predicate keywords inside
`gptel-permit--match-rule-p`; users cannot add custom checkers without
forking. An LLM-as-a-judge that classifies the blast radius of grey-zone
tool calls (bash scripts, evals) needs exactly such an extension point —
regexps cannot triage "runs a python script that only touches ./out"
vs. "writes to /etc". Other harnesses (Claude Code auto mode, Codex
auto-review) show the judge must sit behind deterministic rules, fail
closed, and never be the security boundary.

## What Changes
- `:conditions` cells accept a function as the cdr: called as
  `(funcall CHECKER value tool-call)`, non-nil means the condition matches.
  Sequence short-circuits on the first nil (unchanged behavior).
- The four built-in predicate keywords are extracted into named pure
  functions and resolved through a new `gptel-permit--condition-predicates`
  alist, so users can register/override predicate keywords.
- New condition function `gptel-permit-judge-safe-p`: asks a small local
  model (blocking `gptel-request`, bounded timeout) whether the argument
  value is obviously safe/local. Returns t only on an explicit SAFE verdict.
  The judge can never hard-deny; on SAFE match its rationale is preserved
  for audit. Session history is off by default, opt-in via defcustom.
- Any judge error/timeout/unconfigured/misparse returns nil, so the rule
  simply does not match and evaluation falls through to the next rule.
- New file `gptel-permit-judge.el`; rule-matching capability gains the
  callable-dispatch requirement (spec delta on `rule-engine`).

## Capabilities

### New Capabilities
- `llm-judge`: condition callable that queries a small local model with a
  fixed blast-radius policy (+ optional user policy + optional history) and
  yields a boolean with a retained rationale; fail-closed in all error
  paths; never blocks.

### Modified Capabilities
- `rule-engine`: condition VALUE grammar extended from "regexp string or
  predicate keyword" to also accept a function; predicates moved from
  inline cond branches to named functions in a lookup alist.

## Impact
- `gptel-permit.el`: `gptel-permit--match-rule-p` dispatch refactor;
  four new named predicate functions; new lookup-alist defvar/defcustom.
- `gptel-permit-judge.el` (new): judge defcustoms + condition + prompt
  builder + blocking request helper + verdict parser.
- Hook pipeline: unchanged (`--validate-args`, then `--apply-rules`);
  the judge runs inside rule matching, so a hook invocation may now block
  up to `gptel-permit-judge-timeout` seconds.
- Backward compatible: existing string/keyword conditions behave
  identically.
