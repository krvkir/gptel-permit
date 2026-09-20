# analytics Delta

## ADDED Requirements

### Requirement: Explicit opt-in registration
Analytics SHALL be inert until the user calls
`gptel-permit-register-analytics-hooks` (recommended in a use-package
`:config` section), which SHALL install decision-capture advice, set
`gptel-permit-analytics-enabled` to t, and MAY be undone by
`gptel-permit-unregister-analytics-hooks`. When not registered, no events
SHALL be written, no advice SHALL be active, and no audit sampling SHALL
occur, regardless of other settings.

#### Scenario: Inert by default
- GIVEN a fresh Emacs where the register function was never called
- WHEN a tool call is auto-allowed by a rule
- THEN no analytics file is created or appended and no audit sampling occurs.

#### Scenario: Registration installs advice
- GIVEN analytics was not enabled
- WHEN `gptel-permit-register-analytics-hooks` runs
- THEN advice is present on `gptel--accept-tool-calls`,
  `gptel--reject-tool-calls`, and `gptel--steer-tool-calls`,
  and `gptel-permit-analytics-enabled` is t.

### Requirement: Event schema and storage
Analytics events SHALL be appended as one JSON object per line to
`gptel-permit-analytics-file` (JSONL, append-only; created with 0600
permissions). Every event SHALL carry the common fields:

- `id`: integer correlation id — all events for one tool call share the
  id; ids are monotone and continue after the highest id already in the
  file;
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
serialized distinctly, e.g. `judge:sandbox/deny`). The `verdict` event
SHALL add: `action` (`none` when no rule matched), `confirm` (true,
present only when the verdict asks), `block` (the reason string, present
only on blocks), and — when a judge ran for the call — `judge-model`,
`judge-verdict`, `judge-rationale`. The `audit` event SHALL add `rate`
(the configured sample rate at audit time). The `decision` event SHALL
add `choice` and `wait-ms` (milliseconds between the `confirm` event and
the decision; omitted when the decision could not be correlated).

Record examples (one line each in the file):

    {"id":42,"ts":"2026-10-05T14:30:22.123+0300","type":"tool-call","tool":"Bash","buffer":"proj.org","backend":"OpenAI","model":"gptel-5","args":{"command":"make test"}}
    {"id":42,"ts":"2026-10-05T14:30:22.130+0300","type":"rule-match","tool":"Bash","action":"judge:allow/ask"}
    {"id":42,"ts":"2026-10-05T14:30:22.131+0300","type":"verdict","tool":"Bash","action":"judge:allow/ask","confirm":true,"judge-model":"gptel-5-mini","judge-verdict":"safe","judge-rationale":"only writes inside the project"}
    {"id":42,"ts":"2026-10-05T14:30:22.132+0300","type":"confirm","tool":"Bash"}
    {"id":42,"ts":"2026-10-05T14:30:22.133+0300","type":"audit","tool":"Bash","rate":0.2}
    {"id":42,"ts":"2026-10-05T14:31:04.900+0300","type":"decision","tool":"Bash","choice":"allow","wait-ms":42768}

#### Scenario: Full chain for an asked call
- GIVEN analytics enabled and a call that matches an ask rule
- WHEN the user answers the prompt
- THEN the file contains tool-call, rule-match, verdict, confirm, and
  decision events sharing one id, in that order
- AND the decision event has the user's choice and a wait-ms duration.

#### Scenario: Ids continue across sessions
- GIVEN a file whose highest id is 1000
- WHEN a new Emacs session emits its first event
- THEN that event's id is 1001.

#### Scenario: Judge fields appear only when a judge ran
- GIVEN a call judged by an LLM judge and a call resolved by a plain rule
- WHEN both verdict events are written
- THEN only the judged call's event carries judge-model, judge-verdict,
  and judge-rationale.

### Requirement: Audit sampling of automation allows
When analytics is enabled, the system SHALL with probability
`gptel-permit-analytics-sample-rate` (default 0.2) upgrade an
automation-allow verdict (rule allow, judge-gated sandbox, sandbox) to
`(:confirm t)` and emit an `audit` event. Sampling SHALL NOT apply to
`:block` verdicts.

#### Scenario: Sampled allow asks the user
- GIVEN analytics enabled, sample-rate 1.0, and a rule that auto-allows
- WHEN the call is evaluated
- THEN the hook returns `(:confirm t)` and an audit event is recorded.

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
