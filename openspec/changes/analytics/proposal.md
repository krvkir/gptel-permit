# Proposal: analytics

## Why
To know whether the permission layer is actually reducing prompt fatigue
without sacrificing safety, we need local measurements: how many tool calls
were auto-allowed vs. asked, per-tool and over time, how long users spend on
prompts, and an estimated false-allow rate obtained by auditing a sample of
automation-allowed calls.

## What Changes
- New optional `gptel-permit-analytics.el`: append-only JSONL event log of
  the full decision chain (tool-call, rule-match, verdict incl. judge
  verdict+rationale, confirm shown, user decision with wait time, audit
  markers). Data never leaves the machine — hence "analytics", not telemetry.
- Enablement is explicit: `gptel-permit-register-analytics-hooks` (intended
  for a use-package `:config` section), mirrored by an unregister function.
  A `gptel-permit-analytics-enabled` defcustom (default nil) gates all
  behavior; registering implies enabled. No defcustom-only path.
- Audit sampling: when analytics is enabled, a configurable fraction
  (default 0.2) of automation-allowed calls is up-ranked to a human confirm;
  the user's decision measures false allows. Never applied to blocks.
- Reporting split in two: pure calculator
  `gptel-permit-analytics-compute` (JSONL → stats structure incl. Wilson
  95% CI on the false-allow rate) and formatter
  `gptel-permit-analytics-report` (interactive; renders to a buffer) with
  per-tool and daily/weekly/monthly breakdowns.

## Capabilities

### New Capabilities
- `analytics`: event schema and correlation, opt-in registration, audit
  sampling, decision capture via advice on gptel's three interactive
  tool-call commands, stats computation, and report rendering.

### Modified Capabilities
(none — hooks into existing behavior additively)

## Impact
- `gptel-permit-analytics.el` (new file).
- Touches: `gptel-permit--apply-rules` and the judge gain gated event
  emissions; advice on gptel-internal `gptel--accept-tool-calls`,
  `--reject-tool-calls`, `--steer-tool-calls` (fragile-internal, gated and
  documented).
- Local artifact: `gptel-permit-analytics-file` JSONL (0600).
- Depends on the judge change for rationale capture; designed to degrade
  gracefully when the judge is not loaded.
