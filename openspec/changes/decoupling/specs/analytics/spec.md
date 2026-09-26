# analytics Delta

## MODIFIED Requirements

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
serialized distinctly, e.g. `judge:sandbox/deny`). The `verdict` event
SHALL add: `action` (`none` when no rule matched), `confirm` (true,
present only when the verdict asks), `block` (the reason string, present
only on blocks), and — when a judge ran for the call — `judge-model`,
`judge-verdict`, `judge-rationale`. The `audit` event SHALL add `rate`
(the configured sample rate at audit time). The `decision` event SHALL
add `choice` and `wait-ms` (milliseconds between the `confirm` event and
the decision; omitted when the decision could not be correlated).

Record examples (one line each in the file):

    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.123+0300","type":"tool-call","tool":"Bash","buffer":"proj.org","backend":"OpenAI","model":"gptel-5","args":{"command":"make test"}}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.130+0300","type":"rule-match","tool":"Bash","action":"judge:allow/ask"}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.131+0300","type":"verdict","tool":"Bash","action":"judge:allow/ask","confirm":true,"judge-model":"gptel-5-mini","judge-verdict":"safe","judge-rationale":"only writes inside the project"}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.132+0300","type":"confirm","tool":"Bash"}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:30:22.133+0300","type":"audit","tool":"Bash","rate":0.2}
    {"id":"20261005T143022.123.4242.42","ts":"2026-10-05T14:31:04.900+0300","type":"decision","tool":"Bash","choice":"allow","wait-ms":42768}

#### Scenario: Full chain for an asked call
- GIVEN analytics enabled and a call that matches an ask rule
- WHEN the user answers the prompt
- THEN the file contains tool-call, rule-match, verdict, confirm, and
  decision events sharing one id, in that order
- AND the decision event has the user's choice and a wait-ms duration.

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
