# rule-engine Delta

## MODIFIED Requirements

### Requirement: Rule Structure
A rule SHALL be a plist with keys `:tool`, `:tool-group`, `:conditions`, and
`:action`.

`:conditions` SHALL be an alist of `(TARGET . VALUE)` pairs where:
- TARGET is either a concrete arg keyword (e.g. `:file_path`) or the keyword `:arg-group`.
- VALUE is either a regexp string or a predicate keyword.

`:action` SHALL be one of the action symbols `allow`, `deny`, `ask`,
`sandbox`; the symbol `judge`; or a judge list — a list whose first
element is `judge` followed by one or two action symbols from
`allow`/`deny`/`ask`/`sandbox` (`judge` ≡ `(judge allow ask)`,
`(judge A)` ≡ `(judge A ask)`). Judge actions are resolved by the judge
capability; malformed judge forms SHALL behave as `ask` with a logged
warning.

When `:tool` and `:tool-group` are both present in a rule, `:tool` SHALL
take precedence and a warning SHALL be emitted.

When neither `:tool` nor `:tool-group` is present, the rule SHALL match
any tool.

#### Scenario: Concrete tool rule with regexp condition
- GIVEN the rule `(:tool "Bash" :conditions ((:command . "^openspec [^&|;]*$")) :action allow)`
- WHEN matched against a Bash tool call with `:command "openspec foo"`
- THEN the rule SHALL match and return `allow`.

#### Scenario: Group-targeted rule with regexp condition
- GIVEN the rule `(:tool-group "read" :conditions ((:arg-group "path" . "secret")) :action deny)`
- AND a tool call for "Read" which belongs to the "read" tool-group
- AND the tool call has argument `:file_path` belonging to the "path" arg-group with value "/tmp/secret.txt"
- WHEN the rule engine evaluates this rule
- THEN it SHALL resolve "Read" → tool-group "read", `:file_path` → arg-group "path"
- AND test regexp "secret" against "/tmp/secret.txt" → match
- AND return `deny`.

#### Scenario: Judge action list form
- GIVEN the rule `(:tool "Bash" :conditions ((:command . "^make ")) :action (judge sandbox deny))`
- WHEN matched against a Bash tool call with `:command "make test"`
- THEN the rule SHALL match on its conditions and its resolution SHALL be
  the judge's verdict applied to the two actions (sandbox on SAFE, deny on
  UNSAFE) — evaluation of later rules stops, as with any matched rule.

#### Scenario: Both :tool and :tool-group present
- GIVEN the rule `(:tool "Read" :tool-group "write" :conditions ((:file_path . "secret")) :action deny)`
- WHEN the rule engine evaluates this rule
- THEN it SHALL use `:tool "Read"`
- AND SHALL ignore `:tool-group "write"`
- AND SHALL emit a warning about the ambiguity.

#### Scenario: No tool or tool-group restriction
- GIVEN the rule `(:conditions ((:arg-group "path" . :inside-protected-dirs)) :action ask)`
- AND a tool call for "Read" (any tool) with a path in a protected directory
- WHEN the rule engine evaluates this rule
- THEN the absence of `:tool` and `:tool-group` SHALL mean "match any tool"
- AND the rule SHALL fire.

### Requirement: Action dispatch registry
The rule engine SHALL resolve matched rule actions through a public alist
`gptel-permit-action-handlers` mapping action symbols to handler functions.
A handler SHALL be called with `(ID TOOL-CALL)` — the tool-call id and
the enriched tool call — and SHALL return a verdict plist per the gptel
hook protocol, or nil to defer.

When the matched action is a cons cell (a list form), the engine SHALL
dispatch on its car and SHALL call the handler with the action's cdr as a
third argument: `(funcall handler id tool-call (cdr action))`. A handler
that cannot accept the third argument signals an error, which the engine's
existing error containment SHALL turn into the fail-closed verdict
`(:confirm t)`. Bare-symbol actions SHALL keep the two-argument call.

The built-in actions SHALL be pre-registered with these verdicts:
- `allow` → `(:confirm nil)` (auto-approve),
- `deny` → `(:block "auto-denied")` (reject),
- `ask` → `(:confirm t)` (force prompt).

Optional modules SHALL register their own actions by adding entries to the
registry at module load time, idempotently; the core SHALL contain no
module-specific dispatch code.

When no rule matches, the engine SHALL return nil (defer), as before. When
a rule matches with an action that has no registered handler, the engine
SHALL fail closed with `(:confirm t)` and log the orphaned action. When a
handler itself returns nil, the engine SHALL defer exactly as for a
non-matching call.

#### Scenario: Custom action registered by a module
- GIVEN `gptel-permit-action-handlers` contains an entry mapping `my-action`
  to a handler returning `(:confirm nil)`
- AND a rule matching the call with `:action my-action`
- WHEN the engine processes the call
- THEN the handler SHALL be invoked with the call's id and enriched call
- AND the hook SHALL return `(:confirm nil)`.

#### Scenario: List action passes its cdr to the handler
- GIVEN `gptel-permit-action-handlers` contains an entry mapping `judge` to
  a handler of three arguments
- AND a rule matching the call with `:action (judge sandbox deny)`
- WHEN the engine processes the call
- THEN the handler SHALL be invoked with the call's id, the enriched call,
  and the list `(sandbox deny)` as its third argument.

#### Scenario: Unregistered action fails closed
- GIVEN a matching rule with `:action frobnicate`
- AND no `frobnicate` entry in `gptel-permit-action-handlers`
- AND the tool's own `:confirm` slot is nil
- WHEN the engine processes the call
- THEN the hook SHALL return `(:confirm t)` (it SHALL NOT defer, so the
  tool cannot auto-execute past an unresolved rule).

#### Scenario: Built-in action verdicts
- GIVEN matching rules with actions `allow`, `deny` and `ask`
- WHEN each is processed
- THEN the verdicts SHALL be `(:confirm nil)`, `(:block "auto-denied")`
  and `(:confirm t)` respectively, produced by the registered built-in
  handlers, not by dispatch special cases.

#### Scenario: Handler deferral
- GIVEN a registered handler that returns nil for some calls
- WHEN such a call matches its rule
- THEN the engine SHALL return nil and gptel's `:confirm` fallthrough
  SHALL apply.

## ADDED Requirements

### Requirement: Programmatic tool-call resolution flag
The core SHALL own a dynamic variable `gptel-permit--programmatic-call`
that rule-action implementations bind non-nil while programmatically
accepting or rejecting prompted tool calls (e.g. around a programmatic
`gptel--accept-tool-calls`). Its documentation SHALL describe the flag
generically — advice and hooks may use it to distinguish programmatic
resolutions from interactive user approvals — and SHALL NOT name any
optional module. The core SHALL never set the flag itself outside of
providing its default (nil); only action implementations bind it.

#### Scenario: Flag is core-owned and module-agnostic
- GIVEN the core library loaded with no optional module
- WHEN `gptel-permit--programmatic-call` is inspected
- THEN it is defined, defaults to nil, and its docstring mentions no
  add-on module by name.
