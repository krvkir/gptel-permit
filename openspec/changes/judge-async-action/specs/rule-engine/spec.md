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
