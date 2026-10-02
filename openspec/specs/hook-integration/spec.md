# Hook Integration Specification

## Purpose
Define how gptel-permit integrates with the gptel tool-call pipeline: minor mode with clean load/unload, hook registration, return value semantics, keybinding, and the relationship with tool-level `:confirm` slots.

## Requirements

### Requirement: Minor Mode
gptel-permit SHALL define a minor mode `gptel-permit-mode` that, when enabled, registers the validation and security hooks on `gptel-pre-tool-call-functions` and binds `C-c C-b` in `gptel-tool-call-actions-map`. When disabled, it SHALL remove all registrations.

#### Scenario: Mode enabled adds hooks and keybinding
- GIVEN `gptel-permit-mode` is toggled on
- THEN `gptel-permit--validate-tool-args` SHALL be added to `gptel-pre-tool-call-functions`
- AND `gptel-permit-pre-tool-security-hook` SHALL be added to `gptel-pre-tool-call-functions`
- AND the validation function SHALL appear before the security function in the hook list
- AND `C-c C-b` SHALL be bound to `gptel-permit-confirm-or-add-rule` in `gptel-tool-call-actions-map`.

#### Scenario: Mode disabled removes hooks and keybinding
- GIVEN `gptel-permit-mode` is toggled off
- THEN both hook functions SHALL be removed from `gptel-pre-tool-call-functions`
- AND `C-c C-b` SHALL be unbound from `gptel-tool-call-actions-map` (or restored to previous binding).

#### Scenario: Recommended activation via gptel-mode-hook
- GIVEN the user wants gptel-permit active whenever gptel is active
- THEN the README SHALL recommend `(add-hook 'gptel-mode-hook #'gptel-permit-mode)`.

### Requirement: Hook Input Plist
Both hook functions SHALL receive a plist with keys `:name`, `:args`, `:buffer`, `:backend`, `:model` as provided by gptel's `gptel--handle-pre-tool`.

#### Scenario: Hook receives correct input
- GIVEN a gptel FSM is processing a tool call for "Read" with `:args (:file_path "foo.txt")`
- WHEN `gptel-pre-tool-call-functions` fires
- THEN each hook function SHALL receive a plist containing `:name "Read"`, `:args (:file_path "foo.txt")`, and at minimum `:buffer`, `:backend`, `:model`.

### Requirement: Return Value Protocol
Hook functions SHALL return nil or a plist with keys from the set `:confirm`, `:block`, `:stop`, `:result`, `:args`, `:name`, as defined by gptel's `gptel-pre-tool-call-functions` documentation. A rule action returning `(:confirm nil :args NEWARGS)` SHALL cause gptel to merge NEWARGS into the executing tool-call object, the LLM-visible message history, and the confirmation UI display.

#### Scenario: Validation returns :block for unknown tool
- GIVEN a tool call names an unknown tool
- WHEN validation returns `(:block "...")`
- THEN the gptel FSM SHALL mark the tool call as errored
- AND send the block reason to the LLM as a `<tool_call_error>`.

#### Scenario: Security hook returns :confirm nil (auto-approve)
- GIVEN a rule matches with action `allow`
- WHEN the security hook returns `(:confirm nil)`
- THEN the gptel FSM SHALL store `:confirm nil` on the tool-call
- AND Layer 2 confirmation checks SHALL be skipped
- AND the tool SHALL execute without user prompt.

#### Scenario: Security hook returns :confirm t (force prompt)
- GIVEN a rule matches with action `ask`
- WHEN the security hook returns `(:confirm t)`
- THEN the gptel FSM SHALL store `:confirm t` on the tool-call
- AND the user SHALL be prompted regardless of the tool's `:confirm` slot.

#### Scenario: Security hook returns :args rewrite (sandbox)
- GIVEN a rule matches with action `sandbox`
- WHEN the security hook returns `(:confirm nil :args (:command "bwrap … make test"))`
- THEN the tool SHALL execute with the wrapped command
- AND the rewritten args SHALL be visible in the LLM history and confirm UI.

#### Scenario: Security hook returns nil (defer to tool's :confirm)
- GIVEN no rule matches
- WHEN the security hook returns nil
- THEN the gptel FSM SHALL fall through to the tool's `:confirm` slot
- AND if the tool's `:confirm` is t, the user SHALL be prompted
- AND if the tool's `:confirm` is nil (or absent), the tool SHALL auto-execute.

### Requirement: Precedence Over Tool-Level :confirm
When gptel-permit's hook returns `(:confirm nil)` or `(:confirm t)`, this SHALL override whatever the tool's individual `:confirm` slot specifies, per the gptel hook protocol.

#### Scenario: Hook overrides tool :confirm
- GIVEN a tool has `:confirm t` (always prompt)
- AND a gptel-permit rule matches with action `allow`
- WHEN the hook returns `(:confirm nil)`
- THEN the tool SHALL auto-execute without prompt
- AND the tool's `:confirm t` SHALL be ignored.

#### Scenario: Tool :confirm lambda still runs on fallback
- GIVEN a tool has `:confirm` as a lambda function
- AND no gptel-permit rule matches
- WHEN the hook returns nil
- THEN the gptel FSM SHALL invoke the tool's `:confirm` lambda normally
- AND the lambda's return value SHALL determine confirmation.

### Requirement: Keybinding
gptel-permit-mode SHALL bind `C-c C-b` in `gptel-tool-call-actions-map` to `gptel-permit-add-rule`.

The wizard SHALL ask for the target scope as its last question, after the
tool target, the conditions, and the action, offering the scopes of
`gptel-permit-rule-scopes` and defaulting to `session` — so accepting the
default keeps the previous behavior exactly: the rule goes into
`gptel-permit-rules` and the pending calls are resolved as before. A
non-default answer SHALL store the rule in the chosen scope /only/ and
SHALL NOT duplicate it into the session's rules.

The scope answer SHALL affect only where the rule is stored: the pending
tool calls SHALL be accepted or rejected exactly as today for every
scope, and the verdict SHALL NOT depend on the chosen scope.

A storage failure — an unwritable file, an error while saving — SHALL be
reported to the user and SHALL not silently lose the rule the user just
created: the rule SHALL remain in effect for the session through the
session's rules.

#### Scenario: Interactive rule creation via keybinding
- GIVEN a tool-call confirmation overlay is displayed to the user
- AND `gptel-permit-mode` is active
- WHEN the user presses `C-c C-b`
- THEN `gptel-permit-add-rule` SHALL be invoked
- AND the user SHALL be prompted to select a tool call, argument, regexp, and action
- AND the new rule SHALL be added to `gptel-permit-rules` (the default
  scope being `session`)
- AND it SHALL be applied immediately to pending tool calls.

#### Scenario: Scope is the last question, defaulting to session
- GIVEN the wizard has collected the tool target, the conditions and the
  action
- WHEN the scope prompt is shown
- THEN it SHALL offer `session`, `notebook`, `project` and `global`
- AND the default answer SHALL be `session`
- AND no storage outside the buffer SHALL be touched when the default is
  accepted.

#### Scenario: Choosing notebook persists into the notebook
- GIVEN an Org or markdown notebook buffer and the wizard answered with
  scope `notebook`
- WHEN the rule is created
- THEN the rule SHALL be written into the notebook's own storage
  (`GPTEL_PERMIT_RULES` property, or the `gptel-permit-notebook-rules`
  local variable)
- AND the pending calls SHALL be resolved with the chosen action.

#### Scenario: A disabled scope is not offered
- GIVEN the `project` entry has been removed from the scope
  configuration
- WHEN the scope prompt is shown
- THEN `project` SHALL NOT be among the offered answers
- AND only the scopes still configured SHALL be offered.

#### Scenario: Choosing global persists through Custom
- GIVEN the wizard answered with scope `global`
- WHEN the rule is created
- THEN `gptel-permit-global-rules` SHALL gain the rule through the
  Customize machinery
- AND the pending calls SHALL be resolved with the chosen action.

#### Scenario: Non-default scopes do not duplicate into the session
- GIVEN the wizard answered with scope `project`
- WHEN the rule is created
- THEN the project store SHALL contain the rule
- AND `gptel-permit-rules` SHALL NOT gain a copy of it.

#### Scenario: Persistence failure keeps the rule for the session
- GIVEN a notebook whose file cannot be written and a wizard answer of
  scope `notebook`
- WHEN the rule is created
- THEN the failure SHALL be reported to the user
- AND the rule SHALL be present in `gptel-permit-rules` for the
  remainder of the session
- AND matching SHALL keep honoring it while the session lasts.

### Requirement: Default Global Rules
The README SHALL document a recommended set of `gptel-permit-global-rules` that users can add to their configuration. These rules SHALL include:

- A rule matching path traversal (`".."` or leading `"/"`) on the "write" tool-group's "path" arg-group with action `ask`.
- A rule matching `:inside-project` on "read" tool-group's "path" arg-group with action `allow`.
- A rule matching `:inside-project` on "write" tool-group's "path" arg-group with action `ask`.
- A rule matching `:inside-protected-dirs` on the "path" arg-group with /no tool-group restriction/ (matches all tools) with action `ask`.

#### Scenario: Protected-dirs rule applies to any tool
- GIVEN a global rule `(:conditions ((:arg-group "path" . :inside-protected-dirs)) :action ask)` with no `:tool` or `:tool-group` key
- AND any tool call with a path argument pointing inside a protected directory
- WHEN the rule engine evaluates this rule
- THEN the absence of `:tool`/`:tool-group` SHALL mean "match any tool"
- AND the rule SHALL fire regardless of which tool made the call.
