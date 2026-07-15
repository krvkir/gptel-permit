## Why

When an LLM issues a tool call (such as `Grep` or `Mkdir`) but leaves a path-related argument blank (either omitted entirely or explicitly set to `nil`), the user often expects this to imply "the current directory" or "current project." Currently, rule matching fails on these nil values because they are ignored. Additionally, the interactive rule-creation menu only shows arguments actually present in the tool call, making it impossible to add rule conditions on missing or nil parameters.

## What Changes

- **Rule Engine Path Arg Normalization**: Treat nil or missing arguments belonging to the `path` arg-group as `""` (empty string) for rule matching, allowing `expand-file-name` to resolve them to the current directory.
- **Interactive Rule Menu Insertion**: Always expose arguments belonging to the `path` group in the interactive `C-c C-b` completion menu, even if they are missing or nil in the active tool call.
- **Validation Unaffected**: Structural validation remains unchanged (missing required arguments continue to be blocked before rules run).

## Capabilities

### New Capabilities

### Modified Capabilities
- `rule-engine`: Update nil filepath handling to treat path args as empty string.
- `tool-arg-groups`: Update rules/menu behavior to always expose path arguments.

## Impact

- **Affected Code**: `gptel-permit.el` (rule matching engine and interactive rule creation).
- **APIs**: No breaking changes to existing APIs or public functions.
- **Hooks**: No changes to `gptel-pre-tool-call-functions` registration.
