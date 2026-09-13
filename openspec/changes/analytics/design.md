# Design: analytics

## Context
There is no gptel outcome hook: accept routes through
`gptel--accept-tool-calls`, steer through `gptel--steer-tool-calls`; plain
"cancel" (`gptel--reject-tool-calls`) deletes overlays, emits no signal, and
is resumable — rejection is non-terminal. Hooks receive no tool-call id;
gptel itself correlates post-hoc by name + `equal` args. Verified against
gptel 0.9.9.6.

## Goals / Non-Goals
Goals: complete decision-chain logging when explicitly enabled; false-allow
estimation via sampling; actionable report. Non-goals: exporting data
anywhere; rotation/archival tooling; precise per-call wall-clock of parallel
tool executions (gptel's post hook runs once per turn — out of scope).

## Decisions
- **Registration-as-enablement.** `gptel-permit-register-analytics-hooks`
  adds the advice trio, sets `gptel-permit-analytics-enabled`, and documents
  itself for `use-package :config`. Defcustom alone does nothing until
  registration; unregister removes everything. Transparency: the user sees
  exactly what is installed.
- **Correlation id**: per-call serial scoped by (buffer-name tool
  equal-args) FIFO queue, mirroring gptel's own post-handler matching.
- **Decision capture**: advice on the three interactive commands (only path
  all UI variants funnel through). Cancel is logged as an event with
  `choice: cancel`, never as a final outcome; consumers treat accept/steer
  as terminal.
- **Sampling**: applied at verdict time only when analytics is on;
  `(< (random 100) (* rate 100))` upgrades automation-allow to
  `(:confirm t)` and emits an `audit` event. Blocks are never sampled —
  asking the user to overrule a security veto trains the wrong reflex.
- **Wilson CI** inline (z=1.96); no stats dependency.
- **Rationale on the verdict event**: `judge-verdict` and
  `judge-rationale` fields read from `gptel-permit--last-judge-rationale`
  when the judge package is loaded.

## Risks / Trade-offs
- Advice on three gptel internals may break on upstream changes → fully
  gated, additive, removal on unregister; README marks it fragile.
- Analytics file may contain commands/paths → 0600 permissions, truncated
  values, README warning; disabled by default.
- Buffer-name ambiguity for `:buffer` → events record the name string;
  history-free by design, so no security impact.

## Migration Plan
Ship inert (enabled=nil, no advice) until the user calls the register
function. Rollback: call the unregister function; delete the JSONL.

## Open Questions
None.
