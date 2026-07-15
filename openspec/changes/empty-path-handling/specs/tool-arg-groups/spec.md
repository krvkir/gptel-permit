## ADDED Requirements

### Requirement: Always Expose Path Arguments in Interactive Menu
In the interactive rule-addition command `gptel-permit-add-rule`, any argument belonging to the `path` group in `gptel-permit-tool-groups` for the current tool SHALL be exposed as a selectable option in the completions menu, even if that argument is missing or set to `nil` in the active tool call plist.

#### Scenario: Missing optional path argument is offered in rule menu
- GIVEN a tool call to "Grep" where `:path` is omitted from the arguments list
- WHEN the user invokes `gptel-permit-add-rule` via `C-c C-b`
- THEN the interactive prompt choices list SHALL contain ":path"
- AND the user SHALL be able to select and configure a condition for it.
