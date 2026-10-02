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

`:action` SHALL be one of the action symbols `allow`, `deny`, `ask`,
`sandbox`; the symbol `judge`; or a judge list — a list whose first
element is `judge` followed by one or two action symbols from
`allow`/`deny`/`ask`/`sandbox` (`judge` ≡ `(judge allow ask)`,
`(judge A)` ≡ `(judge A ask)`). Judge actions are resolved by the judge
capability; malformed judge forms SHALL behave as `ask` with a logged
warning.

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

#### Scenario: Judge action list form
- GIVEN the rule `(:tool "Bash" :conditions ((:command . "^make ")) :action (judge sandbox deny))`
- WHEN matched against a Bash tool call with `:command "make test"`
- THEN the rule SHALL match on its conditions and its resolution SHALL be
  the judge's verdict applied to the two actions (sandbox on SAFE, deny on
  UNSAFE) — evaluation of later rules stops, as with any matched rule.

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

Protected-dir entries beginning with `./` SHALL be resolved relative to the
project root (`gptel-permit--project-root`, falling back to
`default-directory`) via `gptel-permit--expand-protected-dir`; all other
entries SHALL be resolved with `expand-file-name`. The same resolution
SHALL be used by the sandbox's protected-path binding, so a single
`gptel-permit-protected-dirs` entry governs both rule matching and
sandboxing. The default value of `gptel-permit-protected-dirs` SHALL
include `./.git`.

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

#### Scenario: inside-protected-dirs containment check
- GIVEN `gptel-permit-protected-dirs` is `("~/.ssh/" "~/.gnupg/")`
- AND a tool-call has `:path "/home/user/.ssh/config"`
- WHEN the predicate `:inside-protected-dirs` is resolved
- THEN `expand-file-name` resolves the path and each protected dir entry
- AND `file-in-directory-p` of the expanded path against "~/.ssh/" returns t
- AND the predicate SHALL return t.

#### Scenario: project-relative protected entry
- GIVEN `gptel-permit-protected-dirs` is `("./.git" "~/.ssh/")` and the
  project root is "/home/user/proj/"
- AND a tool-call has `:path "/home/user/proj/.git/hooks/pre-commit"`
- WHEN the predicate `:inside-protected-dirs` is resolved
- THEN "./.git" resolves to "/home/user/proj/.git"
- AND the predicate SHALL return t.

### Requirement: Match Algorithm — First Match Wins
The rule engine SHALL evaluate rules across four scopes, most specific
first: session, notebook, project, global. The action of the /first/
rule where all conditions match SHALL be returned; no further rules
SHALL be evaluated after a match.

The global rules SHALL always be evaluated last. A scope with no rules
in the current context — no session rules, no notebook store, no
project, no global rules — SHALL contribute nothing and SHALL NOT alter
the outcome.

#### Scenario: Session rule overrides global rule
- GIVEN `gptel-permit-rules` contains `(:tool "Read" :conditions ((:file_path . "logs")) :action allow)`
- AND `gptel-permit-global-rules` contains `(:tool "Read" :conditions ((:file_path . "logs")) :action ask)`
- WHEN matching a Read tool call with `:file_path "logs/debug.txt"`
- THEN the session rule SHALL match first
- AND the returned action SHALL be `allow`
- AND the global rule SHALL NOT be evaluated.

#### Scenario: Notebook rule overrides project and global rules
- GIVEN the notebook carries `(:tool "Bash" :action allow)`
- AND the project carries `(:tool "Bash" :action ask)`
- AND the session has no rules
- WHEN matching a Bash tool call
- THEN the notebook rule SHALL match first
- AND the returned action SHALL be `allow`
- AND neither the project nor the global rule SHALL be evaluated.

#### Scenario: Project rule overrides a global rule
- GIVEN the project carries `(:tool-group read :action deny)`
- AND the global rules hold an allow rule for the `read` group
- WHEN matching a Read tool call
- THEN the project rule SHALL match first
- AND the returned action SHALL be `deny`.

#### Scenario: Deferral only when every scope is exhausted
- GIVEN a session rule and a project rule that do not match the call
- AND a global rule that does
- WHEN the engine evaluates rules
- THEN every scope SHALL have offered its rules before the global rule
  is reached
- AND the global rule SHALL match and decide.

#### Scenario: No rule matches — fallback
- GIVEN no rule in session-local or global rules matches the tool call
- WHEN the engine evaluates all rules
- THEN the return value SHALL be nil
- AND the caller SHALL defer to Layer 2 (tool's `:confirm` slot).

#### Scenario: No persisted rules means today's behavior
- GIVEN no notebook property and no project store exist
- WHEN a matching global rule is evaluated
- THEN the verdict SHALL be identical to the engine's behavior before
  scopes existed.

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
When `gptel-permit-log-enabled` is non-nil, the rule engine SHALL log
the full resolution chain for each rule evaluation, including tool-group
and arg-group expansions, regexp matches, and predicate resolutions. The
chain SHALL additionally name the scope whose rule matched and, for a
scope whose rules can come from several places, where the rule came
from — the store file for a project rule, the heading or the file level
for an Org notebook rule — so a surprising auto-allow can be traced back
to the exact rule that authorized it.

#### Scenario: Logged group resolution
- GIVEN `gptel-permit-log-enabled` is t
- AND a rule targeting tool-group "read"
- WHEN matched against a "Read" tool call
- THEN the log SHALL contain information showing "Read" resolves to tool-group "read"
- AND for each condition the log SHALL show the arg resolved through its arg-group.

#### Scenario: Matched scope and store are logged
- GIVEN `gptel-permit-log-enabled` is t
- AND the first matching rule comes from a subfolder store of the
  project scope
- WHEN a tool call is processed
- THEN the log SHALL record that the matching rule's scope is `project`
- AND the log SHALL name that store's file.

#### Scenario: Matched notebook heading is logged
- GIVEN `gptel-permit-log-enabled` is t
- AND the first matching rule comes from the `GPTEL_PERMIT_RULES` value
  of a heading in an Org notebook
- WHEN a tool call is processed
- THEN the log SHALL record that the matching rule's scope is `notebook`
- AND the log SHALL name that heading.

#### Scenario: No-match log names no scope
- GIVEN `gptel-permit-log-enabled` is t
- AND no rule in any scope matches the call
- WHEN the call is processed
- THEN the log SHALL record the absence of a match without naming a
  contributing scope.

### Requirement: Early Return Guard
The security hook function SHALL skip tool calls that already have `:result` or `:error` set (i.e., already processed by an earlier hook function such as validation).

#### Scenario: Skipping already-processed tool call
- GIVEN the validation hook (earlier on the same hook) returned `:block` for a tool call, setting `:result` on it
- WHEN the security hook runs on the same tool call
- THEN it SHALL detect the `:result` key
- AND return nil immediately without evaluating any rules.

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

### Requirement: Rule scopes
The system SHALL organize rules into four ordered scopes — `session`,
`notebook`, `project`, `global` — evaluated most specific first, from
the narrowest to the broadest. The ordered list of scopes is user-visible configuration:
`gptel-permit-rule-scopes`. Removing a scope's entry from it — the
entire scope, not some of its rules — SHALL disable that scope
entirely: its rules SHALL NOT apply, and its store SHALL not even be
read. Adding an entry SHALL enable a new scope without any other
configuration or code change. The scope order SHALL be the sole
determinant of precedence; no other setting SHALL alter which rule wins.

A rule's scope is the user's choice at creation time through the rule
wizard (see the hook-integration capability).

#### Scenario: Scope order decides which rule speaks
- GIVEN one rule matching the call in each scope, with different actions:
  session `ask`, notebook `allow`, project `deny`, global `allow`
- WHEN a tool call is processed
- THEN the returned action SHALL be `ask`
- AND the reported scope SHALL be `session`.

#### Scenario: Disabling a scope stops its rules
- GIVEN the `project` entry has been removed from
  `gptel-permit-rule-scopes` (the entire scope, not some of its rules)
- AND the project's rules contain a matching `allow` rule
- WHEN a tool call is processed
- THEN the project store SHALL not even be read
- AND the project rule SHALL NOT apply
- AND the verdict SHALL come from a narrower scope, from the global
  rules, or from the tool's own `:confirm` fallthrough.

#### Scenario: An empty scope contributes nothing
- GIVEN no notebook rules and no project rules exist for the call's
  context
- WHEN a tool call is processed
- THEN matching SHALL proceed over session and global rules exactly as
  it would with the empty scopes removed.

### Requirement: Rule origin introspection
When the engine collects rules from a scope's readers, each rule SHALL
carry its origin: the scope it came from and — where the scope can
supply rules from more than one place — that place. A project rule's
origin SHALL name its store file; an Org notebook rule's origin SHALL
name the heading it came from, or mark the file level; a markdown
notebook rule's origin SHALL name the notebook file. Session and global
rules SHALL carry origins too (the session buffer, the Customize
option).

An origin SHALL be visible in the diagnostic log for any matched rule
and SHALL be observable on the enriched tool call of a matched call
(see the rule-engine-hooks capability). Origins are bookkeeping, not
rule data: a collected rule's origin SHALL be assigned by its reader,
overwriting any store-supplied copy; the origin SHALL be inert during
matching, SHALL never be written back into any store, and SHALL NOT be
reported by analytics, which keeps its coarse `scope` field.

#### Scenario: A project rule's origin names its store file
- GIVEN a matching allow rule in
  `/home/user/proj/gui/.gptel-permit-rules`
- WHEN its call is matched
- THEN the rule's origin SHALL identify scope `project`
- AND the origin SHALL name that file.

#### Scenario: An Org notebook rule's origin names its heading
- GIVEN a matching rule stored in a heading's `GPTEL_PERMIT_RULES`
  value of an Org notebook
- WHEN its call is matched
- THEN the rule's origin SHALL identify scope `notebook`
- AND the origin SHALL name that heading
- AND a rule resolved at file level SHALL carry a file-level origin
  instead.

#### Scenario: Origins never persist and never touch matching
- GIVEN a project store whose rules carry no origin fields
- AND a store whose rules carry a stale or hand-forged origin field
- WHEN rules are collected from both
- THEN each collected rule SHALL carry an origin freshly assigned by
  the reader, overwriting whatever the store carried
- AND a later store write SHALL contain no origin field
- AND matching SHALL be unaffected by the presence of an origin field.

### Requirement: Session scope
Rules scoped to a session SHALL live in the buffer where they were
created: they SHALL govern only that buffer, SHALL take precedence over
every other scope, and SHALL never outlive the buffer — not written to
any file, not restored when the notebook is reopened.

#### Scenario: Session rules are not persisted
- GIVEN a rule created through the wizard with scope `session`
- WHEN the notebook file is saved and reopened in a fresh Emacs
- THEN the rule SHALL be absent from the reopened session
- AND it SHALL still govern every call in the session where it was
  created.

### Requirement: Notebook scope
A rule scoped to a notebook SHALL be bound to that one notebook file: it
SHALL govern tool calls made from that notebook, and, once saved, SHALL
govern them again in later sessions whenever the file is opened. It
SHALL NOT govern tool calls from any other notebook or session.

In an Org notebook the rules live in the `GPTEL_PERMIT_RULES` property.
The file-level property SHALL govern calls from anywhere in the
notebook. A heading that sets its own property SHALL govern the calls
made with point inside its subtree, overriding every broader value; a
subtree that sets none SHALL inherit the nearest ancestor's value, and
ultimately the file-level one. Rules created through the rule wizard
SHALL always land at file level, so a rule created with point inside
some subtree is still notebook-wide.

In a markdown notebook the rules live in the standard local variable
`gptel-permit-notebook-rules`, applied by Emacs when the file is opened.
Visiting a markdown notebook that carries rules SHALL NOT prompt the
user about local variables.

#### Scenario: File-level property applies to the whole notebook
- GIVEN an Org notebook whose file-level property holds one rule
  allowing the `read` tool group
- WHEN a Read tool call is processed from anywhere in the notebook
- THEN the notebook rule SHALL match
- AND a Bash call SHALL NOT match it.

#### Scenario: Heading property scopes rules to its subtree
- GIVEN a file-level `allow` rule and a heading whose own property holds
  a `deny` rule for the same target
- WHEN a matching tool call is processed with point inside that
  heading's subtree
- THEN the heading's rule SHALL decide the verdict
- AND under every other heading the file-level rule SHALL decide.

#### Scenario: Nearest ancestor heading wins
- GIVEN a file-level rule, a parent heading with its own value, and a
  nested child heading that sets none
- WHEN a matching tool call is processed with point under the child
  heading
- THEN the parent heading's value SHALL govern
- AND the file-level value SHALL NOT decide.

#### Scenario: A rule created inside a subtree is still notebook-wide
- GIVEN point inside a heading's body whose own property differs from
  the file level
- WHEN the wizard persists a rule into the notebook scope
- THEN the file-level property SHALL gain the rule
- AND the heading's own property SHALL stay unchanged.

#### Scenario: Repeated writes update one property
- GIVEN an Org notebook that already carries a file-level
  `GPTEL_PERMIT_RULES` property
- WHEN the wizard persists another rule into the notebook scope
- THEN the same property SHALL be updated
- AND the buffer SHALL NOT gain a second `GPTEL_PERMIT_RULES` property.

#### Scenario: Drawer position does not matter
- GIVEN an Org notebook laid out as `#+TITLE: …` followed by the
  properties drawer that holds `GPTEL_PERMIT_RULES`
- WHEN a tool call is processed with point outside any heading
- THEN the notebook rules SHALL apply
- AND their effect SHALL NOT differ from a drawer placed before the
  keyword line.

#### Scenario: Notebook rules survive reopening
- GIVEN a notebook rule persisted in an Org notebook and the file saved
- WHEN the buffer is killed and the file reopened in a fresh Emacs
- THEN the rule SHALL govern tool calls from the reopened notebook
  without being re-created.

#### Scenario: Narrowing does not hide notebook rules
- GIVEN an Org notebook with a narrowing in effect over one subtree
- WHEN a tool call is processed
- THEN the notebook rules SHALL resolve exactly as if no narrowing were
  in effect.

#### Scenario: Markdown notebook persists and reloads without prompting
- GIVEN a markdown notebook
- WHEN the wizard persists a rule into the notebook scope and the file
  is saved and reopened in a fresh Emacs
- THEN the reopened notebook SHALL carry the rule and apply it
- AND Emacs SHALL NOT prompt about local variables for it.

### Requirement: Project scope
A rule scoped to a project SHALL apply to tool calls from every notebook
located inside one project, where the project of a notebook is the root
reported for its directory by Emacs's project system (version control or
any other project backend), or — when that directory is not part of any
project and the notebook visits a file — that file's own folder.

The project SHALL keep its rules in `.gptel-permit-rules` files: one
printed rule per line, with `;` comments and blank lines allowed,
hand-editable at any time. Every directory on the chain from the
notebook's own directory up to and including the project root may hold
such a store, and all of them SHALL be consulted together, nearest
first: for a given call, the rule of the store closest to the notebook
SHALL decide, and stores further up SHALL fill wherever the closer
ones are silent. The walk SHALL stop at the project root: a store in a
directory above the root (e.g. the user's home directory) SHALL NOT be
read — policy spanning several projects is the global scope's business.

Storing a rule SHALL append it to the project root's store, as resolved
at creation time — never to a store in a deeper hand-chosen directory —
creating the file when missing, and SHALL NOT modify any file outside
the project root. Project rules SHALL take effect for the next tool
call after any store in the chain is created or edited — no restart,
no buffer revisit.

When no project can be resolved for the notebook's context, the project
scope SHALL contribute no rules.

#### Scenario: Project rule matches a notebook in the project
- GIVEN a repository at `/home/user/proj` with a `.git` directory
- AND `/home/user/proj/.gptel-permit-rules` containing
  `(:tool-group read :conditions ((:arg-group "path" . :inside-project)) :action allow)`
- AND a notebook `/home/user/proj/notes.org` used as a session buffer
- WHEN a Read tool call is processed in that session
- THEN the project rule SHALL match
- AND it SHALL outrank any global rule.

#### Scenario: No project, no project rules
- GIVEN no project is active for the notebook's directory
- AND the notebook visits no file
- WHEN a tool call is processed
- THEN no project rule SHALL apply
- AND matching SHALL proceed with the remaining scopes.

#### Scenario: Hand edits are picked up immediately
- GIVEN a project store edited between two tool calls
- WHEN the next tool call is processed
- THEN the store's new contents SHALL govern
- AND no restart of Emacs or revisit of the notebook SHALL be needed.

#### Scenario: Comments and multiple forms parse
- GIVEN a project store containing a leading comment line, two rule
  forms, and a trailing comment
- WHEN the store is read
- THEN it SHALL yield exactly the two rules, in file order.

#### Scenario: Inner store decides, outer store fills
- GIVEN a project store at the root carrying `ask` for Bash and `deny`
  for Read
- AND a store in the notebook's subfolder carrying `allow` for Bash and
  nothing for Read
- WHEN a Bash tool call is processed from the subfolder
- THEN the subfolder rule SHALL decide (`allow`)
- AND the root store's Bash rule SHALL NOT be evaluated
- WHEN a Read tool call is processed from the subfolder
- THEN the subfolder store SHALL contribute nothing
- AND the root store's Read rule SHALL decide (`deny`).

#### Scenario: A store above the project root is not read
- GIVEN `.gptel-permit-rules` in the user's home directory with a
  matching `allow` rule
- AND a project rooted below the home directory containing a notebook
- WHEN a tool call is processed in that notebook
- THEN the home store SHALL NOT be read
- AND the verdict SHALL come from another scope or defer, never from
  the home store.

#### Scenario: Storing a project rule touches nothing outside the root
- GIVEN a repository with an existing `.gptel-permit-rules`
- WHEN the wizard stores a project rule
- THEN the only file whose contents change SHALL be that store
- AND the rule SHALL be appended without replacing the existing rules.

### Requirement: Global scope
Global rules SHALL apply to every session, regardless of project or
notebook, and SHALL be consulted last: every narrower scope offering a
matching rule SHALL outrank them.

Storing a global rule SHALL update the running value and the user's
custom file through the Customize machinery — as if the user had saved
the option themself — and SHALL NOT touch any project or notebook file.

#### Scenario: Global rules are the last resort
- GIVEN a notebook rule and a global rule both matching a call
- WHEN the call is processed
- THEN the notebook rule SHALL decide the verdict
- AND the global rule SHALL NOT be evaluated.

#### Scenario: Persisting globally updates the running value
- GIVEN the wizard persists a rule into the `global` scope
- WHEN the option is inspected in the same session
- THEN `gptel-permit-global-rules` SHALL contain the new rule
- AND the change SHALL have been saved through the Custom machinery.

### Requirement: Persisted rules are data, not code
Rules read from any persisted scope (notebook, project) SHALL be
validated before they participate in matching. A value SHALL be accepted
as a rule only when it is a plist with keyword keys, and each of its
condition values is a string, a predicate keyword, or a symbol naming a
function.

A condition value that is a lambda or other cons form, or any other
unsupported shape, SHALL cause that rule to be rejected: it SHALL be
skipped, it SHALL NOT be matched, and the rejection SHALL be logged.
Rejected rules SHALL NOT make the call fail; matching SHALL continue
with the remaining rules.

Session and global rules are supplied by the user's own configuration
and SHALL keep today's behavior, including callable conditions written
as lambdas.

#### Scenario: Lambda condition in a persisted store is skipped
- GIVEN a project store containing a rule whose condition value is a
  lambda form
- AND a global rule matching the same call with action `ask`
- WHEN the call is processed
- THEN the persisted rule SHALL be rejected and logged
- AND the global rule SHALL decide the verdict.

#### Scenario: Named function conditions remain usable
- GIVEN a project store containing a rule with a condition value naming
  a function symbol
- WHEN the call is processed
- THEN the rule SHALL be accepted
- AND the named function SHALL be called as a condition.

#### Scenario: Malformed persisted data does not break matching
- GIVEN a notebook property holding forms that are not rule plists
- WHEN a tool call is processed
- THEN those values SHALL be skipped
- AND the engine SHALL still return the verdict of the first valid
  matching rule, or defer when none matches.

### Requirement: Persisted store failures fail closed
A persisted store that cannot be read or parsed — an unreadable file, a
store with a syntax error, anywhere a scope reads (including any store
in the project chain) — SHALL never auto-run a tool: the session SHALL
confirm the call instead. A single malformed rule inside an otherwise
readable store SHALL only disqualify that rule (see "Persisted rules
are data, not code") and SHALL NOT fail the whole store.

#### Scenario: Unreadable project store forces confirmation
- GIVEN a project store that cannot be parsed
- WHEN a tool call is processed
- THEN the hook SHALL return `(:confirm t)`
- AND the call SHALL NOT be auto-approved by a global allow rule.

#### Scenario: A broken notebook property forces confirmation
- GIVEN an Org notebook whose `GPTEL_PERMIT_RULES` value does not parse
- WHEN a tool call is processed
- THEN the hook SHALL return `(:confirm t)`
- AND the call SHALL NOT be auto-approved by a global allow rule.

#### Scenario: A broken subfolder store forces confirmation
- GIVEN a valid project store at the root with a matching allow rule
- AND `.gptel-permit-rules` in the notebook's subfolder that does not
  parse
- WHEN a tool call is processed from that subfolder
- THEN the hook SHALL return `(:confirm t)`
- AND the root store's allow SHALL NOT auto-approve the call.

### Requirement: Project rules opt-out
The project scope SHALL be able to be disabled entirely: with the option
`gptel-permit-project-rules-enabled` off, no project store SHALL be read
and no repository-shipped rule SHALL influence a verdict. A disabled
project scope SHALL also accept no new rules: storing one SHALL be
refused with a report naming the disabled option, and the rule SHALL
stay in effect for the session only, as with any storage failure (see
the hook-integration capability). The default SHALL be on, and the
documentation SHALL present project rules as trusted like a repository's
`.dir-locals.el`.

#### Scenario: Project rules disabled
- GIVEN `gptel-permit-project-rules-enabled` is nil
- AND a project store containing a matching allow rule
- WHEN a tool call is processed
- THEN the project store SHALL NOT be read
- AND the verdict SHALL come from another scope or defer.

#### Scenario: A disabled project scope accepts no rules
- GIVEN `gptel-permit-project-rules-enabled` is nil
- WHEN the wizard is answered with scope `project`
- THEN the refusal SHALL be reported to the user, naming the option
- AND the rule SHALL be kept for the session instead of the project
  store.