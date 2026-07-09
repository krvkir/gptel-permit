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
Hook functions SHALL return nil or a plist with keys from the set `:confirm`, `:block`, `:stop`, `:result`, `:args`, `:name`, as defined by gptel's `gptel-pre-tool-call-functions` documentation.

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
gptel-permit-mode SHALL bind `C-c C-b` in `gptel-tool-call-actions-map` to `gptel-permit-confirm-or-add-rule`.

#### Scenario: Interactive rule creation via keybinding
- GIVEN a tool-call confirmation overlay is displayed to the user
- AND `gptel-permit-mode` is active
- WHEN the user presses `C-c C-b`
- THEN `gptel-permit-confirm-or-add-rule` SHALL be invoked
- AND the user SHALL be prompted to select a tool call, argument, regexp, and action
- AND the new rule SHALL be added to `gptel-permit-rules`
- AND it SHALL be applied immediately to pending tool calls.

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
