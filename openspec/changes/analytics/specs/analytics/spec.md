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
`gptel-permit-analytics-file`, each carrying `:id`, `:ts`, and a `:type` of
`tool-call`, `rule-match`, `verdict`, `confirm`, `decision`, or `audit`.
Verdict events for judged calls SHALL include the judge model, verdict, and
rationale. The file SHALL be created with 0600 permissions; argument values
SHALL be truncated.

#### Scenario: Full chain for an asked call
- GIVEN analytics enabled and a call that matches an ask rule
- WHEN the user answers the prompt
- THEN the file contains tool-call, rule-match, verdict, confirm, and
  decision events sharing one :id, and the decision event has the user's
  choice and a wait-ms duration.

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
breakdowns (daily/weekly/monthly), and false-allow stats (audited count,
user-overridden count, rate, Wilson 95% confidence interval).
`gptel-permit-analytics-report` SHALL render that structure readably into a
buffer. The two SHALL be independent functions so the data is scriptable.

#### Scenario: False-allow rate from audit events
- GIVEN 10 audit events where the user rejected 2 automation-allowed calls
- WHEN `gptel-permit-analytics-compute` runs
- THEN false-allows reports audited 10, overridden 2, rate 0.2, and a
  Wilson 95% interval covering 0.2.
