# analytics Specification

## Purpose
Record every permission decision to an append-only local JSONL log and
derive statistics from it: how often rules auto-approve versus how often a
human is asked, how long users take to confirm, and the false-allow rate
measured by audit sampling of automation-allow verdicts. Capture is inert
until `gptel-permit-register-analytics-hooks` runs, and it flows entirely
through the core engine hooks and advice on gptel's interactive tool-call
commands — the rule engine never calls into analytics by name.

## Requirements
### Requirement: Explicit opt-in registration
Analytics SHALL be inert until the user calls
`gptel-permit-register-analytics-hooks` (recommended in a use-package
`:config` section), which SHALL install decision-capture advice, add its
observer to `gptel-permit-events-functions`, add its audit predicate to
`gptel-permit-veto-functions`, set `gptel-permit-analytics-enabled` to t,
and MAY be undone by `gptel-permit-unregister-analytics-hooks` (which
removes the hook additions and the advice). When not registered, no events
SHALL be written, no advice SHALL be active, and no audit sampling SHALL
occur, regardless of other settings. The core rule engine SHALL NOT call
into the analytics module by name; all capture SHALL flow through the core
engine hooks.

#### Scenario: Inert by default
- GIVEN a fresh Emacs where the register function was never called
- WHEN a tool call is auto-allowed by a rule
- THEN no analytics file is created or appended and no audit sampling occurs.

#### Scenario: Registration installs advice and hook functions
- GIVEN analytics was not enabled
- WHEN `gptel-permit-register-analytics-hooks` runs
- THEN advice is present on `gptel--accept-tool-calls`,
  `gptel--reject-tool-calls`, and `gptel--steer-tool-calls`,
  AND the analytics observer is present on `gptel-permit-events-functions`,
  AND the audit predicate is present on `gptel-permit-veto-functions`,
  and `gptel-permit-analytics-enabled` is t.

### Requirement: Event schema and storage
Analytics events SHALL be appended as one JSON object per line to
`gptel-permit-analytics-file` (JSONL, append-only; created with 0600
permissions). Every event SHALL carry the common fields:

- `id`: string tool-call id minted by the rule engine as
  `TIMESTAMP.PID.SERIAL` — all events for one tool call share the id, and
  ids are unique across sessions and concurrent Emacs processes without
  coordination or file seeding. Records written before this change carry
  integer ids; statistics SHALL fold both shapes with equal semantics;
- `ts`: ISO-8601 timestamp with millisecond precision;
- `type`: one of `tool-call`, `rule-match`, `verdict`, `confirm`, `audit`,
  `decision`;
- `tool`: the tool name (omitted only for the id-less minibuffer-cancel
  decision).

Events SHALL NOT store period grouping fields: the daily, weekly and
monthly breakdowns are derived from `ts` when statistics are computed.

The `tool-call` event SHALL add: `buffer` (name or null), `backend`
(name or null), `model` (name or null), and `args` — an object mapping
argument names to truncated string values. The `rule-match` event SHALL
add `action` (the matched action as a string; list-form judge actions are
serialized distinctly, e.g. `judge:sandbox/deny`), and — when a rule
matched — `scope`: the name of the scope (as a string, e.g. `session`,
`notebook`, `project`, `global`) whose rule matched. The `verdict` event
SHALL add: `action` (`none` when no rule matched), the same `scope` field
when a rule matched, `confirm` (true, present only when the verdict asks),
`block` (the reason string, present only on blocks), and — when a judge
ran for the call — `judge-model`, `judge-verdict`, `judge-rationale`. The
`audit` event SHALL add `rate` (the configured sample rate at audit time).
The `decision` event SHALL add `choice` and `wait-ms` (milliseconds
between the `confirm` event and the decision; omitted when the decision
could not be correlated).

The `scope` field SHALL be omitted for calls no rule matched, and records
written before scopes existed SHALL fold with equal semantics (a missing
`scope` is treated as unknown, never as a mismatch).

Record examples (one line each in the file):

    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.123+0300","type":"tool-call","tool":"Bash","buffer":"proj.org","backend":"OpenAI","model":"gptel-5","args":{"command":"make test"}}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.130+0300","type":"rule-match","tool":"Bash","action":"judge:allow/ask","scope":"project"}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.131+0300","type":"verdict","tool":"Bash","action":"judge:allow/ask","scope":"project","confirm":true,"judge-model":"gptel-5-mini","judge-verdict":"safe","judge-rationale":"only writes inside the project"}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.132+0300","type":"confirm","tool":"Bash"}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.133+0300","type":"audit","tool":"Bash","rate":0.2}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:31:04.900+0300","type":"decision","tool":"Bash","choice":"allow","wait-ms":42768}

#### Scenario: Full chain for an asked call
- GIVEN analytics enabled and a call that matches an ask rule
- WHEN the user answers the prompt
- THEN the file contains tool-call, rule-match, verdict, confirm, and
  decision events sharing one id, in that order
- AND the decision event has the user's choice and a wait-ms duration.

#### Scenario: Matched scope is recorded
- GIVEN analytics enabled and a call whose first matching rule comes
  from the notebook scope
- WHEN the rule-match and verdict events are written
- THEN both events SHALL carry `scope` `notebook`
- AND the value SHALL identify the scope that authorized the verdict.

#### Scenario: No-match records carry no scope
- GIVEN analytics enabled and a call that matches no rule in any scope
- WHEN its rule-match and verdict events are written
- THEN neither event SHALL carry a `scope` field
- AND the verdict event's action SHALL still be `none`.

#### Scenario: Legacy records without scope still fold
- GIVEN a log file whose rule-match and verdict records have no `scope`
  field (written before scopes existed)
- WHEN `gptel-permit-analytics-compute` runs
- THEN every chain SHALL fold into one outcome row as before
- AND the missing scope SHALL NOT cause a parse failure or a mismatch.

#### Scenario: Ids are unique across sessions without seeding
- GIVEN a log file from a previous Emacs session
- WHEN a new Emacs session emits its first event
- THEN that event's id SHALL be a fresh string whose timestamp is the
  current session's time and whose pid is the current process's —
  independent of any id already in the file.

#### Scenario: Mixed legacy and new ids fold correctly
- GIVEN a log file containing complete chains with integer ids (legacy)
  and complete chains with string ids
- WHEN `gptel-permit-analytics-compute` runs
- THEN every chain SHALL fold into one outcome row each, with integer-id
  and string-id chains counted and broken down identically.

#### Scenario: Judge fields appear only when a judge ran
- GIVEN a call judged by an LLM judge and a call resolved by a plain rule
- WHEN both verdict events are written
- THEN only the judged call's event carries judge-model, judge-verdict,
  and judge-rationale.

### Requirement: Audit sampling of automation allows
When analytics is enabled, the system SHALL with probability
`gptel-permit-analytics-sample-rate` (default 0.2) upgrade an
automation-allow verdict (rule allow, judge-gated sandbox, sandbox) to
`(:confirm t)` and emit an `audit` event. The sampling decision SHALL be
made by the analytics audit predicate on `gptel-permit-veto-functions`;
the verdict upgrade SHALL be performed by the rule engine, which preserves
any `:args` rewrite. The audit predicate SHALL emit the audit event itself
when it selects a call, and its errors SHALL fail the call closed.
Sampling SHALL NOT apply to `:block` verdicts, nor to calls no rule
matched.

#### Scenario: Sampled allow asks the user
- GIVEN analytics enabled, sample-rate 1.0, and a rule that auto-allows
- WHEN the call is evaluated
- THEN the hook returns `(:confirm t)` and an audit event is recorded.

#### Scenario: Sampled sandbox verdict is confirmed with rewritten args
- GIVEN analytics enabled, sample-rate 1.0, and a matching sandbox rule
- WHEN the call is evaluated and the sandbox handler returns
  `(:confirm nil :args (:command "wrapped"))`
- THEN the hook returns `(:confirm t :args (:command "wrapped"))` — the
  user confirms the sandboxed command, not the original.

#### Scenario: Blocks never sampled
- GIVEN analytics enabled and a deny rule match
- WHEN the call is evaluated
- THEN the verdict is `:block` regardless of sample rate.

### Requirement: User decision capture
The system SHALL record the user's resolution of a tool-call prompt when
analytics is enabled, by advising `gptel--accept-tool-calls`,
`gptel--reject-tool-calls`, and `gptel--steer-tool-calls`, capturing the
decision time and choice (allow / cancel / steer). A cancel SHALL be logged
as an event, not a terminal outcome (gptel permits resuming canceled calls).

#### Scenario: Accept recorded with wait time
- GIVEN a confirm event at time T0
- WHEN the user accepts via the overlay key at T1
- THEN a decision event records `allow` and wait-ms T1−T0.

### Requirement: Decision correlation across arg rewrites
The decision event SHALL still correlate with the original confirm event when
a tool call's arguments are rewritten between the confirmation event
and the user (or programmatic) acceptance — e.g. interactive sandboxed
acceptance wrapping `:command` via `gptel-permit-accept-tool-calls-sandboxed`
(the pending-confirmation entry SHALL be popped with the pre-rewrite
arguments), so wait-time statistics remain correct. The rewrite itself
SHALL be recorded by carrying the wrapped arguments in the decision event's
tool-call payload, keeping the decision auditable against what actually ran.

#### Scenario: Sandbox hotkey decision correlates
- GIVEN analytics enabled and a pending Bash confirmation with args
  `(:command "make test")`
- WHEN the user accepts via `C-c C-s` and the sandboxed command runs
- THEN a decision event records `allow` with the correct wait-ms from the
  original confirm timestamp
- AND the decision event's payload carries the wrapped command string, not
  the original.

### Requirement: Statistics computation and report
`gptel-permit-analytics-compute` SHALL read the JSONL file and return a pure
data structure with: total calls, auto-allowed count, asked count, blocked
count, per-tool breakdown (calls, asked, ask-rate, average wait), period
breakdowns (daily/weekly/monthly, derived from the events' `ts`
timestamps rather than stored fields), and false-allow stats (audited
count, user-overridden count, rate, Wilson 95% confidence interval).
`gptel-permit-analytics-report` SHALL render that structure readably into a
buffer. The two SHALL be independent functions so the data is scriptable.

#### Scenario: False-allow rate from audit events
- GIVEN 10 audit events where the user rejected 2 automation-allowed calls
- WHEN `gptel-permit-analytics-compute` runs
- THEN false-allows reports audited 10, overridden 2, rate 0.2, and a
  Wilson 95% interval covering 0.2.

#### Scenario: Period breakdowns derive from timestamps
- GIVEN event records carrying `ts` and no period fields
- WHEN `gptel-permit-analytics-compute` runs
- THEN the daily, weekly and monthly breakdowns group the calls by period
  values derived from the timestamps.

### Requirement: Judge verdict events
The event schema SHALL include the `judge-verdict` event type. When a judge
action resolves a call (synchronously or asynchronously), a `judge-verdict`
event SHALL be emitted carrying the verdict (including the failure classes
`parse-fail`, `request-fail`, `timeout`), the rationale, the judged
argument value, and the judge latency in milliseconds, correlated with the
original tool-call event's id. Asynchronous verdicts SHALL be emitted from
the verdict-owning buffer's context so per-call judge state is current.

#### Scenario: Async SAFE chain
- GIVEN analytics enabled and an async `judge` call answered SAFE
- WHEN the callback resolves and the pack auto-accepts
- THEN the file contains tool-call, rule-match, verdict, confirm,
  judge-verdict (verdict `safe`, with rationale and latency) and decision
  (choice `auto-allow`) events sharing one id.

#### Scenario: Async UNSAFE stays manual
- GIVEN analytics enabled and an async judge call answered UNSAFE whose
  resolution is `ask`
- THEN a judge-verdict event records `unsafe`
- AND the user's later manual decision event records their choice with a
  wait time measured from the original confirm event.

### Requirement: Programmatic judge decisions
Programmatic judge resolutions SHALL be recorded as `decision` events with
choices distinct from user decisions: an auto-accepted pack SHALL record
`auto-allow` (not the user's `allow`) and an auto-rejected pack SHALL
record `deny`. Pending-confirmation entries SHALL be popped with the
pre-rewrite arguments when the resolution rewrites them (the sandbox
analytics requirement), so wait times correlate correctly. The
decision-capture advice SHALL treat tool-call approvals made while the
core's `gptel-permit--programmatic-call` flag is bound non-nil as
programmatic resolutions and SHALL NOT record them as user decisions; the
programmatic resolver emits the `decision` event itself.

#### Scenario: Auto-reject is distinguishable
- GIVEN analytics enabled and an async `(judge sandbox deny)` call
  answered UNSAFE
- WHEN the callback rejects the pack
- THEN the decision event's choice is `deny` and the judge-verdict event
  carries the rationale fed to the model.

### Requirement: Audit sampling of judge-gated calls
Audit sampling SHALL extend to judge-gated calls in every mode: when
sampling selects such a call, the judge SHALL still be evaluated and the
verdict recorded (an `audit` event plus the `judge-verdict` event), but
the resolution SHALL be the manual confirmation regardless of the verdict
— a sampled call SHALL never be programmatically accepted or rejected.
This measures judge false-positives and false-UNSAFE rates alike. In
synchronous mode the engine's existing veto consult already covers the
judge's resolution verdict; in asynchronous mode the resolution callback
SHALL consult `gptel-permit-veto-functions` with the would-be resolution
verdict before applying it, and a non-nil veto SHALL force the manual
resolution. Neither path references any analytics symbol outside the
analytics module.

#### Scenario: Sampled SAFE does not auto-accept
- GIVEN analytics enabled, sample-rate 1.0, and an async `judge` call
  answered SAFE
- WHEN the resolution is computed
- THEN the pack stays on the prompt, audit and judge-verdict events are
  recorded
- AND the user's manual decision is captured as usual.

### Requirement: Judge action serialization
Event fields recording the matched rule's action SHALL serialize list-form
judge actions distinctly (e.g. `(judge sandbox deny)` as
`judge:sandbox/deny`), so rule-match and verdict events remain well-formed
for list actions.

#### Scenario: List action serializes
- GIVEN analytics enabled and a call matching a rule with
  `:action (judge sandbox deny)`
- WHEN the rule-match event is emitted
- THEN its action field is the string `judge:sandbox/deny`.

