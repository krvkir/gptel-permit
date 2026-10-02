# analytics Delta

## MODIFIED Requirements

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

## Implementation details

- The `scope` value is read from the enriched tool call's `:rule-scope`
  annotation (see the rule-engine-hooks capability) at emission time in
  the analytics observers, converted to a string with `symbol-name`.
- The field is omitted when the key is absent (no rule matched) or nil —
  which is exactly the shape of every pre-scope record, so legacy
  folding is a no-op rather than a migration.
- Only the `rule-match` and `verdict` events carry `scope`; the
  `tool-call`, `confirm`, `audit` and `decision` events remain
  scope-free, so the examples above stay the complete schema picture.
