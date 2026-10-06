# rule-engine-api Delta

## ADDED Requirements

### Requirement: Public module-interface helpers
The core package SHALL publish five public helper functions as the
module interface, spelled without the private `--` separator:
`gptel-permit-log`, `gptel-permit-truncate-arg`,
`gptel-permit-project-root`, `gptel-permit-expand-protected-dir` and
`gptel-permit-emit-event`.

- `gptel-permit-log (FORMAT-STRING &rest ARGS)` SHALL log to the
  `*gptel-permit-log*` buffer, gated by `gptel-permit-log-enabled`, in
  the format `[%Y-%m-%d %H:%M:%S] MESSAGE`.
- `gptel-permit-truncate-arg (ARG)` SHALL return a string representation
  of ARG truncated to the first 30 and last 30 characters joined by
  `...` when longer than 60 characters, and SHALL never signal.
- `gptel-permit-project-root ()` SHALL return the current project's root
  directory, else the visited file's directory, else nil.
- `gptel-permit-expand-protected-dir (DIR &optional ROOT)` SHALL resolve
  a `gptel-permit-protected-dirs` entry against the project root for
  `./`-prefixed entries and via `expand-file-name` otherwise, and SHALL
  return nil for a non-string DIR.
- The five helpers SHALL behave identically in every installed-subset
  configuration, and SHALL NOT read any optional module's state.

#### Scenario: Log helper gates on the option
- GIVEN `gptel-permit-log-enabled` is nil and the analytics or judge
  module calls `gptel-permit-log`
- THEN the returned value SHALL be nil, no buffer SHALL be created, and
  no text SHALL be inserted.

#### Scenario: Truncate-arg bounds output length
- GIVEN an argument value whose printed representation is 200
  characters
- WHEN `gptel-permit-truncate-arg` is called on it
- THEN the result SHALL be a string of at most 63 characters
  and SHALL contain the first 30 and the last 30 characters.

#### Scenario: Core-only install keeps helpers working
- GIVEN only the `gptel-permit` package is installed
- WHEN `gptel-permit-project-root` is called in a project buffer and
  `gptel-permit-emit-event` is called with a tool call and an event type
- THEN the first SHALL return the project root string or nil without
  error, and the second SHALL deliver the event to
  `gptel-permit-events-functions` observers (or no one, when the hook is
  empty) without signaling.

### Requirement: Observer-side event emission
Optional modules SHALL emit module-defined events through the public
`gptel-permit-emit-event` entry point rather than by walking
`gptel-permit-events-functions` themselves. A module-emitted event
SHALL use the same `(ID TOOL-CALL TYPE PAYLOAD)` delivery contract, an
open TYPE vocabulary (an observer meets an unknown TYPE as data), and
MUST NOT be able to alter a verdict: per-observer error isolation and
never-signaling delivery are guaranteed by the core function alone.

The judge module's `:judge-verdict` event (payload plist `:verdict`,
`:rationale`, `:arg`, `:latency-ms`) is the first module-emitted event
type and SHALL remain part of the delivered vocabulary the analytics
observer consumes.

#### Scenario: Judge verdict event traverses to observers
- GIVEN the judge module is loaded and the analytics observer is
  registered on `gptel-permit-events-functions`
- WHEN the judge's async resolution calls `gptel-permit-emit-event` with
  type `:judge-verdict`
- THEN the analytics observer SHALL receive `(ID TOOL-CALL
  :judge-verdict PAYLOAD)` and SHALL record a `judge-verdict` JSONL
  event for the call's id, without the judge having touched the hook
  variable directly.

#### Scenario: Module emission cannot alter a verdict
- GIVEN a module calls `gptel-permit-emit-event` while a verdict is
  being computed
- AND one registered observer signals an error
- THEN the remaining observers SHALL still receive the event, and the
  verdict under computation SHALL be unchanged by either the error or
  the event.

### Requirement: Documented dynamic-scope contracts
The four dynamic variables that optional modules read or bind across
package boundaries SHALL be documented in one place (the
`rule-engine-api` capability) with their owner, shape and binding
discipline, and each defining `defvar`/`defvar-local` in code SHALL
carry the same contract in its docstring:

- `gptel-permit--programmatic-call` (core-owned, special): non-nil while
  a module programmatically resolves a prompted call; the core never
  binds it; decision-capture advice uses it to skip programmatic
  resolutions.
- `gptel-permit--last-judge-verdict`,
  `gptel-permit--last-judge-rationale` (judge-owned, buffer-local): the
  most recent judge verdict and rationale (or full raw response on
  `parse-fail`); nil when the judge did not run; reset per tool call.
- `gptel-permit-judge-model` (judge-owned): the judge model name
  recorded by analytics verdict fields.
- `gptel-permit-sandbox--rewritten-args` (sandbox-owned, special): the
  alist of `(NEW-ARGS . OLD-ARGS)` bound around a sandboxed acceptance,
  by which decision capture correlates a rewritten accept to the
  confirmation pended under the original arguments.

Analytics' cross-module reads of the judge and sandbox variables SHALL
remain guarded — `(featurep 'gptel-permit-judge)` for the judge block,
an empty binding meaning "no correlation" for the sandbox alist — and
SHALL yield omitted record fields, never errors, in any installed
subset.

#### Scenario: Analytics without judge omits judge fields
- GIVEN analytics is installed and registered, the judge package is not
  installed, and a rule-matched call produces a verdict
- WHEN the verdict event is recorded
- THEN the JSONL record SHALL carry no `judge-model`, `judge-verdict` or
  `judge-rationale` field, and SHALL NOT signal.

#### Scenario: Analytics without sandbox skips rewrite correlation
- GIVEN analytics installed, the sandbox package not installed, and no
  `gptel-permit-sandbox--rewritten-args` binding in force
- WHEN an accept decision is recorded for pended confirmation
- THEN the decision SHALL be recorded under the call's original args,
  with the sandbox correlation branch a silent no-op.

#### Scenario: The dynamic contracts are documented in one place
- GIVEN a reader of the `rule-engine-api` spec
- THEN the spec SHALL name all four contracts with owner and shape
- AND the core shall not be required to know the judge's or sandbox's
  internals to enforce them.
