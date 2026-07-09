# Tool and Argument Groups Specification

## Purpose
Decouple permission rules from concrete tool definitions by introducing an indirection layer: tool-groups and argument-groups. A rule may target a group instead of a specific tool name or argument key.

## Requirements

### Requirement: Tool-Group Mapping
The system SHALL maintain a `defcustom` mapping each concrete tool name to a tool-group name and each of its argument keys to optional arg-group names.

#### Scenario: Default grouping for gptel-agent tools
- GIVEN the `gptel-permit-tool-groups` defcustom
- WHEN the system is loaded
- THEN "Read", "Glob", and "Grep" SHALL belong to the "read" tool-group by default
- AND "Write", "Edit", "Insert", and "Mkdir" SHALL belong to the "write" tool-group by default
- AND "Bash" SHALL belong to the "shell" tool-group by default
- AND their path-related arguments (`:file_path`, `:path`, `:parent`, `:filename`) SHALL all belong to the "path" arg-group.

#### Scenario: User extends groups for custom tools
- GIVEN a user adds a custom tool "UploadFile" with arguments `:target_path` and `:content`
- WHEN the user appends an entry to `gptel-permit-tool-groups`
- THEN "UploadFile" SHALL resolve to its declared tool-group and its arguments SHALL resolve to their declared arg-groups when matching rules.

#### Scenario: Tool not found in mapping
- GIVEN a tool call for "UnknownTool"
- WHEN the group resolver looks up "UnknownTool" in `gptel-permit-tool-groups`
- THEN the resolver SHALL return nil for both tool-group and arg-groups
- AND group-targeted rules SHALL NOT match this tool call.

### Requirement: Arg-Group Resolution
When a rule targets an arg-group, the matching engine SHALL check every argument of the tool-call that belongs to that group. If any such argument's value satisfies the condition regexp, the condition is considered satisfied.

#### Scenario: Arg-group condition matches via any grouped arg
- GIVEN a rule targeting arg-group "path" with regexp "secret"
- AND a tool-call for "Read" with args `(:file_path "/tmp/public.txt" :start_line 1 :end_line 10)`
- WHEN the engine resolves arg-group "path"
- THEN `:file_path` SHALL be identified as belonging to the "path" group
- AND the regexp "secret" SHALL be tested against the expanded value of `:file_path`
- AND since "/tmp/public.txt" does not match "secret", the condition SHALL fail.

#### Scenario: Arg-group matches on any qualifying arg
- GIVEN a rule targeting arg-group "path" with regexp "secret"
- AND a tool-call for "Edit" with args `(:path "/tmp/public.txt" :old_str "foo" :new_str "bar")`
- WHEN the engine resolves arg-group "path"
- THEN `:path` SHALL be identified as belonging to the "path" group
- AND since "/tmp/public.txt" does not match "secret", the condition SHALL fail
- AND no other args belong to "path", so the condition fails.

#### Scenario: Multiple args in same arg-group
- GIVEN a rule targeting arg-group "path" with regexp "secret"
- AND a tool-call for "Write" with args `(:path "/tmp" :filename "secret.txt" :content "hello")`
- WHEN the engine resolves arg-group "path"
- THEN both `:path` and `:filename` SHALL be identified as belonging to the "path" group
- AND `:filename` value "secret.txt" SHALL match "secret"
- AND the condition SHALL succeed regardless of `:path` not matching.

### Requirement: Rule Target Resolution Precedence
When a rule specifies both a concrete target and a group target, the concrete target SHALL take precedence.

#### Scenario: Concrete tool name overrides tool-group
- GIVEN a rule with `:tool "Read"` and `:tool-group "write"`
- WHEN the engine matches this rule
- THEN the `:tool` key SHALL be used for matching
- AND the `:tool-group` key SHALL be ignored.

#### Scenario: Explicit arg-key overrides arg-group in a condition
- GIVEN a rule condition `(:file_path . "secret")` where `:file_path` is a concrete argument key
- WHEN the engine evaluates this condition
- THEN it SHALL match against `:file_path` directly
- AND it SHALL NOT resolve it through the arg-group system
- EVEN IF `:file_path` also belongs to an arg-group.

### Requirement: Tool-Group Defaults Defcustom
The system SHALL provide `gptel-permit-tool-groups` as a defcustom mapping tool names to plists of `(:tool-group <name> :arg-groups ((<arg-key> . <group-name>) ...))`.

#### Scenario: Validating the defcustom type
- GIVEN the `gptel-permit-tool-groups` defcustom
- THEN its type SHALL be an alist
- AND each value SHALL be a plist with optional keys `:tool-group` (symbol) and `:arg-groups` (alist of symbol → symbol)
- AND missing `:tool-group` or `:arg-groups` SHALL be valid (omission means no group membership).
