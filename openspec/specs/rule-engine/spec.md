# Rule Engine Specification

## Purpose
Match tool calls against permission rules, supporting both concrete tool/arg targets and group-based targets, regexp conditions and predicate conditions, and deterministic action resolution with session-local rules taking precedence over global rules.
## Requirements
### Requirement: Rule Structure
A rule SHALL be a plist with keys `:tool`, `:tool-group`, `:conditions`, and `:action`.

`:conditions` SHALL be an alist of `(TARGET . VALUE)` pairs where:
- TARGET is either a concrete arg keyword (e.g. `:file_path`) or the keyword `:arg-group`.
- VALUE is one of: a regexp string, a predicate keyword, or a function
  called as `(funcall VALUE arg-value tool-call)` whose non-nil return means
  the condition matches.

When `:tool` and `:tool-group` are both present in a rule, `:tool` SHALL take precedence and a warning SHALL be emitted.

When neither `:tool` nor `:tool-group` is present, the rule SHALL match any tool.

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

#### Scenario: Callable condition matches
- GIVEN a rule `(:tool-group execute :conditions ((:command . my-safe-p)) :action sandbox)`
- AND `my-safe-p` is a function that returns t for read-only commands
- WHEN matched against a Bash tool call with `:command "ls"`
- THEN the engine SHALL call `my-safe-p` with the `:command` value and the
  tool-call plist, and the non-nil result SHALL make the condition match.

#### Scenario: Callable condition short-circuits
- GIVEN a rule with two conditions, the first a callable that returns nil,
  the second a callable
- WHEN the rule is evaluated
- THEN evaluation SHALL stop after the first nil condition
- AND the second callable SHALL NOT be invoked.

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

### Requirement: Predicate Conditions
The system SHALL support predicate keywords resolved at match time through
a lookup alist `gptel-permit--condition-predicates` mapping each keyword to a
named function called with `(value tool-call)`; the alist SHALL be user
extensible.

The built-in predicates SHALL include:
- `:inside-project` — true if the normalized path is inside the current project root or buffer file directory.
- `:outside-project` — true if the normalized path is outside the current project root / buffer file directory, or if neither can be resolved.
- `:inside-protected-dirs` — true if the normalized path is inside any directory listed in `gptel-permit-protected-dirs`.
- `:path-traversal` — true if the path contains `..` or is absolute.

When the predicate keyword does not match any entry, the condition SHALL fail with a logged warning.

#### Scenario: inside-project on a file in the project root
- GIVEN `default-directory` is "/home/user/myproject/"
- AND `(project-current)` returns a project with root "/home/user/myproject/"
- AND a tool-call has `:file_path "src/main.el"`
- WHEN the predicate `:inside-project` is resolved
- THEN `expand-file-name` resolves to "/home/user/myproject/src/main.el"
- AND `file-in-directory-p` against the project root returns t
- AND the predicate SHALL return t.

#### Scenario: outside-project when no project is active
- GIVEN `(project-current)` returns nil
- AND `(buffer-file-name)` returns nil
- AND a tool-call has `:file_path "/tmp/scratch.txt"`
- WHEN the predicate `:outside-project` is resolved
- THEN no base directory can be resolved
- AND the predicate SHALL return t (conservative: treat everything as outside).

#### Scenario: Custom predicate keyword registered
- GIVEN a user adds `(:inside-secrets . my-secrets-p)` to
  `gptel-permit--condition-predicates`
- WHEN a rule uses condition value `:inside-secrets`
- THEN the engine SHALL call `my-secrets-p` for the match.

### Requirement: Match Algorithm — First Match Wins
The rule engine SHALL evaluate rules in order: session-local rules (`gptel-permit-rules`) first, then global rules (`gptel-permit-global-rules`). The action of the /first/ rule where all conditions match SHALL be returned. No further rules SHALL be evaluated after a match.

#### Scenario: Session rule overrides global rule
- GIVEN `gptel-permit-rules` contains `(:tool "Read" :conditions ((:file_path . "logs")) :action allow)`
- AND `gptel-permit-global-rules` contains `(:tool "Read" :conditions ((:file_path . "logs")) :action ask)`
- WHEN matching a Read tool call with `:file_path "logs/debug.txt"`
- THEN the session rule SHALL match first
- AND the returned action SHALL be `allow`
- AND the global rule SHALL NOT be evaluated.

#### Scenario: No rule matches — fallback
- GIVEN no rule in session-local or global rules matches the tool call
- WHEN the engine evaluates all rules
- THEN the return value SHALL be nil
- AND the caller SHALL defer to Layer 2 (tool's `:confirm` slot).

### Requirement: Path Argument Normalization
When matching a condition against an argument value, if the argument key is recognized as a path key or if it belongs to an arg-group whose semantics are path-based, the value SHALL be expanded with `expand-file-name` before regexp matching or predicate evaluation.

Path-based arg-groups SHALL be declared as a property of the arg-group definition, not inferred from argument key names.

#### Scenario: Path expansion on arg-group "path"
- GIVEN the arg-group "path" is declared as path-semantic
- AND `default-directory` is "/home/user/"
- AND a tool-call has `:path "docs/readme.txt"`
- WHEN matching a condition `(:arg-group "path" . "^docs/")`
- THEN the value SHALL be expanded to "/home/user/docs/readme.txt"
- AND "docs/" SHALL NOT match "/home/user/docs/readme.txt" (no leading ^ match)
- AND the condition SHALL fail.

### Requirement: Nil Filepath Handling
When an argument with path semantics (belonging to the `path` arg-group) is explicitly `nil` or completely absent/missing from the tool call arguments list, any rule condition targeting it SHALL treat its value as `""` (empty string) for rule matching. This empty string SHALL be expanded via `expand-file-name`, resolving it to the current directory (`default-directory`).

#### Scenario: Nil path argument matches wildcards
- GIVEN a Glob tool call with `:path nil`
- AND a rule condition `(path . ".*")`
- WHEN the engine evaluates this condition
- THEN the value nil SHALL be treated as `""`
- AND expanded to the current `default-directory`
- AND matched against the condition, succeeding.

#### Scenario: Missing optional path argument matches project predicate
- GIVEN a Grep tool call where `:path` is omitted from the arguments list
- AND a rule condition `(path . :inside-project)`
- AND the current `default-directory` is inside the active project root
- WHEN the engine evaluates this condition
- THEN the missing `:path` argument SHALL be treated as `""`
- AND expanded to the current directory
- AND matched against the `:inside-project` predicate, succeeding.

### Requirement: Path Traversal as Default Rule
The hard-coded path traversal check for Write/Mkdir (`".."` and leading `"/"`) SHALL be removed. Traversal detection SHALL be part of the recommended default rules in `gptel-permit-global-rules`.

#### Scenario: Traversal detected via rule
- GIVEN a default global rule `(:tool-group "write" :conditions ((:arg-group "path" . "^\\\\.\\\\.|^/")) :action ask)`
- AND a Write tool call with `:filename "../etc/passwd"`
- WHEN the engine evaluates rules
- THEN the rule SHALL match
- AND the action SHALL be `ask` (prompt the user)
- AND the call SHALL NOT be silently blocked.

### Requirement: Diagnostic Logging
When `gptel-permit-log-enabled` is non-nil, the rule engine SHALL log the full resolution chain for each rule evaluation, including tool-group and arg-group expansions, regexp matches, and predicate resolutions.

#### Scenario: Logged group resolution
- GIVEN `gptel-permit-log-enabled` is t
- AND a rule targeting tool-group "read"
- WHEN matched against a "Read" tool call
- THEN the log SHALL contain information showing "Read" resolves to tool-group "read"
- AND for each condition the log SHALL show the arg resolved through its arg-group.

### Requirement: Early Return Guard
The security hook function SHALL skip tool calls that already have `:result` or `:error` set (i.e., already processed by an earlier hook function such as validation).

#### Scenario: Skipping already-processed tool call
- GIVEN the validation hook (earlier on the same hook) returned `:block` for a tool call, setting `:result` on it
- WHEN the security hook runs on the same tool call
- THEN it SHALL detect the `:result` key
- AND return nil immediately without evaluating any rules.

