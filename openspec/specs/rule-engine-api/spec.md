# Rule Engine API Specification

## Purpose
The cross-package module interface: the public helpers the three
optional packages (gptel-permit-judge, gptel-permit-sandbox,
gptel-permit-analytics) and third-party event sources may call, and the
dynamic-scope contracts they exchange. Everything else dash-prefixed in
the core is private.

The rule engine's extension surface: core-minted tool-call ids that need
no consumer coordination, a uniform callback signature for action handlers
and engine hooks, and the three engine hooks — per-call state lifecycle
(`gptel-permit-before-rule-match-functions`), event observation
(`gptel-permit-events-functions`), and verdict veto
(`gptel-permit-veto-functions`) — through which optional modules extend
the engine without the core containing any module-specific code.

## Requirements
### Requirement: Core-minted tool-call ids
The rule engine SHALL mint one tool-call id per processed pre-tool call,
unconditionally — including when no hook functions are registered. The id
SHALL be a string of the form `TIMESTAMP.PID.SERIAL` (local timestamp with
millisecond precision, the Emacs process id, a process-wide serial), unique
across sessions, across concurrent Emacs processes, and across calls within
a session, without coordination with any consumer. Minting SHALL NOT read
or depend on any analytics module state, including its log file.

#### Scenario: Ids are formatted and unique within a session
- GIVEN a session buffer in which two tool calls are processed
- WHEN both calls are evaluated by the security hook
- THEN each call's events SHALL carry one string id matching
  `^[0-9]\{8\}T[0-9]\{6\}\.[0-9]\{3\}\.[0-9]+\.[0-9]+$`, and the two
  calls' ids SHALL be distinct.

#### Scenario: Minting needs no consumers
- GIVEN `gptel-permit-events-functions`, `gptel-permit-veto-functions`
  and `gptel-permit-before-rule-match-functions` are all nil
- AND the analytics module is not loaded
- WHEN a matching allow rule is evaluated
- THEN the hook SHALL return `(:confirm nil)` exactly as with observers
  present, and no file or module state SHALL be touched.

### Requirement: Uniform engine callback signature
Every engine callback — action handlers and the functions on the three engine hooks — SHALL receive the tool-call ID as its first argument and the enriched TOOL-CALL as its second argument.
Callback-specific arguments follow. Any callback that needs neither
SHALL declare them with underscore names.

#### Scenario: Signature consistency probe
- GIVEN a probe function registered on each of the three engine hooks
  and a probe action handler registered in `gptel-permit-action-handlers`
- WHEN a matching tool call is processed
- THEN each probe SHALL have been called with the call's id in argument
  position 1 and the enriched tool-call plist in position 2.

### Requirement: Before-rule-match hook
`gptel-permit-before-rule-match-functions` SHALL be an abnormal hook run
exactly once per processed tool call, after the `:tool-call` event is
observed and before rule matching begins, called with
`(ID TOOL-CALL)`. Return values SHALL be ignored. Errors from hook
functions SHALL NOT be caught at the hook site: they SHALL propagate into
the security hook's fail-closed error handling (`(:confirm t)`).

#### Scenario: State prepared before matching
- GIVEN a module function on the hook that clears a buffer-local variable
- AND a rule whose condition populates that same variable
- WHEN a tool call is processed twice, the first call populating it
- THEN at the start of the second call's rule matching the variable SHALL
  be nil (the hook ran before matching), and the second call's verdict
  event SHALL carry no trace of the first call's value.

#### Scenario: Erroring lifecycle function fails closed
- GIVEN a function on `gptel-permit-before-rule-match-functions` that
  signals an error
- WHEN a tool call is processed
- THEN the security hook SHALL return `(:confirm t)`.

### Requirement: Events hook
`gptel-permit-events-functions` SHALL be an abnormal hook observing the
engine's events, called with `(ID TOOL-CALL TYPE PAYLOAD)` where TYPE is
one of `:tool-call`, `:rule-match`, `:verdict` or `:confirm`, and PAYLOAD
is nil for `:tool-call` and `:confirm`, the matched action symbol (nil when
no rule matched) for `:rule-match`, and `(ACTION . VERDICT)` for
`:verdict`. The `:rule-match` event SHALL fire at the point the match
decision is made — inside the matcher on the first matching rule, or once
with nil action after all rules failed. Each observer function SHALL run
isolated in `condition-case`: an erroring observer SHALL be logged and
SHALL NOT alter the verdict nor prevent later observers from running.
Observer return values SHALL be ignored.

#### Scenario: Allow chain observed in order
- GIVEN an observer recording (TYPE PAYLOAD) pairs and a matching allow
  rule
- WHEN the call is processed
- THEN the observer SHALL have seen `:tool-call`, then `:rule-match` with
  `allow`, then `:verdict` with `(allow . (:confirm nil))`, and no
  `:confirm` event.

#### Scenario: Ask chain includes a confirm event
- GIVEN an observer and a matching ask rule
- WHEN the call is processed
- THEN the chain SHALL end with a `:verdict` event followed by a
  `:confirm` event for the same id.

#### Scenario: No-match chain observes defer without confirm
- GIVEN an observer and no matching rule
- WHEN the call is processed
- THEN the observer SHALL have seen `:rule-match` with nil action and a
  `:verdict` event whose action is nil, and no `:confirm`.

#### Scenario: Erroring observer is isolated
- GIVEN two observers, the first signalling an error
- WHEN a matching allow rule is processed
- THEN the verdict SHALL still be `(:confirm nil)` and the second observer
  SHALL have seen all events.

### Requirement: Extensible event set
The set of event types delivered on `gptel-permit-events-functions` SHALL
be open, not exhaustive: the engine MAY emit additional event types in
future versions, through the same hook, with the same
`(ID TOOL-CALL TYPE PAYLOAD)` signature and the same per-function error
isolation; the payload of a new type is defined when that type is added.
A new event type SHALL NOT change the meaning, payload or per-chain
position of the existing types. Observer functions SHALL treat an unknown
TYPE as data, not as an error.

#### Scenario: An unknown event type reaches observers unchanged
- GIVEN an observer recording every (TYPE PAYLOAD) pair it receives
- WHEN an event with a TYPE outside the current enumeration is emitted
  through the events hook (as a future engine version may)
- THEN the observer SHALL have recorded that pair without error
- AND the observer SHALL still receive the later events of the same
  call's chain.

### Requirement: Veto hook
`gptel-permit-veto-functions` SHALL be an abnormal hook run with
`run-hook-with-args-until-success` after a verdict is computed and before
it is returned, called with `(ID TOOL-CALL VERDICT)`, and only when a rule
matched (the action SHALL be non-nil). A non-nil return SHALL make the
engine — not the veto function — upgrade the verdict to `(:confirm t)`,
preserving any `:args` rewrite. Veto functions SHALL NOT return modified
verdicts; they inspect and veto. Errors from veto functions SHALL NOT be
caught at the hook site: they SHALL fail the call closed (`(:confirm t)`).

#### Scenario: Vetoed sandbox verdict keeps its rewrite
- GIVEN a veto function that always returns t
- AND a matched rule whose registered handler returns
  `(:confirm nil :args (:command "wrapped"))`
- WHEN the call is processed
- THEN the returned verdict SHALL be `(:confirm t :args (:command
  "wrapped"))` — forced confirmation of the *rewritten* call.

#### Scenario: First positive predicate wins
- GIVEN two veto functions, both recording their invocation, the first
  returning t
- WHEN a matched call is processed
- THEN the verdict SHALL be upgraded and the second function SHALL NOT
  have been invoked.

#### Scenario: Deferred calls are not vetoed
- GIVEN a veto function that always returns t
- AND no matching rule
- WHEN the call is processed
- THEN the veto function SHALL NOT have been invoked and the hook SHALL
  return nil (defer to the tool's `:confirm` fallthrough).

#### Scenario: Erroring veto function fails closed
- GIVEN a veto function that signals an error
- WHEN a matched allow call is processed
- THEN the security hook SHALL return `(:confirm t)`.

### Requirement: Matched scope and origin on the tool call
When a rule matches, the engine SHALL annotate the enriched tool call
with the scope that produced the match and with that rule's origin —
where the rule came from — from the moment of the match decision
onward. Observers on `gptel-permit-events-functions` SHALL therefore be
able to name the scope and the exact source (a store file, a notebook
heading, the session buffer, the Custom option) that authorized a call
at every remaining event of that call's chain (`:rule-match`,
`:verdict`, `:confirm`).

The annotations SHALL NOT change any event payload: `:rule-match`
remains the matched action symbol, `:verdict` remains
`(ACTION . VERDICT)`, `:tool-call` remains nil; consumers that inspect
only payloads SHALL be unaffected. When no rule matched, neither scope
nor origin SHALL be reported.

#### Scenario: Scope is observable at the match event
- GIVEN an observer recording (TYPE, ACTION, SCOPE) triples
- AND the first matching rule comes from the notebook scope
- WHEN a tool call is processed
- THEN the observer SHALL see `:rule-match` with the matched action and
  the scope `notebook`
- AND the following `:verdict` event's tool call SHALL report the same
  scope.

#### Scenario: Origin rides with the scope
- GIVEN an observer recording the tool call at each event
- AND the first matching rule comes from a subfolder store of the
  project scope
- WHEN a tool call is processed
- THEN the call SHALL carry the scope `project`
- AND the call SHALL carry an origin identifying that store file.

#### Scenario: No match reports no scope
- GIVEN an observer and no matching rule in any scope
- WHEN the call is processed
- THEN the `:rule-match` event SHALL carry a nil action
- AND the call SHALL report no matched scope and no origin.

#### Scenario: Payload shape is unchanged
- GIVEN an observer recording the raw payload of every event
- AND a matching allow rule in the project scope
- WHEN the call is processed
- THEN the `:rule-match` payload SHALL be the action symbol `allow`
- AND the `:tool-call` payload SHALL be nil
- AND the `:verdict` payload SHALL be `(allow . (:confirm nil))`.

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
