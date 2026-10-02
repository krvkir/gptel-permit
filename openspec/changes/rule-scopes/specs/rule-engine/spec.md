# rule-engine Delta

## MODIFIED Requirements

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

## ADDED Requirements

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

## Implementation details

The scopes are one public configuration surface plus per-scope storage:

- `gptel-permit-rule-scopes` is an ordered, public alist mapping a scope
  symbol to a plist with `:reader` and `:writer` functions; its order
  *is* the match order, and the engine iterates it, hardcoding no scope
  names. A `:reader` is called with no arguments in the session buffer —
  which is already the notebook buffer, since `gptel--handle-pre-tool`
  runs the hook inside `with-current-buffer` — and returns that scope's
  rule list or nil when the scope has no storage in the current context.
  A `:writer` is called as `(rule)` and persists one rule, returning the
  stored rule or signaling an error on failure. Adding an entry adds a
  scope; removing one disables it. This follows the house pattern of
  `gptel-permit-action-handlers` and the sandbox registries:
  user-visible, inert, symbol-keyed data.

Per-scope storage:

- `session` is the buffer-local `gptel-permit-rules` (an unchanged
  `defvar-local`; the session write path remains
  `(push rule gptel-permit-rules)`).
- `notebook`, Org: the property `GPTEL_PERMIT_RULES` holds the rules as
  their printed Lisp form, parsed with `read`, ignored when absent.
  Reading happens inside `org-with-wide-buffer` in two steps:
  (1) `org-entry-get` at `(point)` with inheritance `t` — the entry
  under point, else the nearest ancestor heading that sets the property;
  (2) when that is nil, the first
  `:[ \t]*GPTEL_PERMIT_RULES:[ \t]*VALUE` property line before the first
  headline (the file-level drawer). The second step is mandatory:
  `org-entry-get` at `(point-min)` does not see a drawer that follows a
  keyword line such as `#+TITLE:` — verified on Emacs 31.1: with the
  drawer after `#+TITLE`, both `org-entry-get (point-min) … t` and
  `org-property-values` return nil, while a drawer placed before any
  keyword is found. Per-heading rules come from the full inheritance `t`
  (`org-use-property-inheritance` defaults to nil, so the `'selective`
  flag would see nothing). The reader returns nil outside `org-mode`
  and when Org cannot be loaded; Org is required lazily, not at load
  time.
- `notebook`, markdown: the file-local variable
  `gptel-permit-notebook-rules` — `defvar-local` with a
  `safe-local-variable` property (a list predicate, registered before
  the package loads), written with `add-file-local-variable` and removed
  with `delete-file-local-variable`; Emacs applies it during its
  `hack-local-variables` pass on visit. Without the safe property Emacs
  silently refuses the value (verified), which is why the property is
  registered. A user with `enable-local-variables` nil gets no markdown
  scope. This is gptel's own markdown notebook mechanism —
  `gptel--bounds` lives in the same `Local Variables:` block — so no
  secondary YAML/TOML convention is invented.
- `notebook`, the writer: always targets the file-level drawer, never
  the heading under point. The merged list is the file-level value alone
  (the second lookup step, never the entry value under point) with the
  new rule appended, so a heading override is neither duplicated into
  the notebook-wide list nor promoted. An existing file-level property
  line is replaced in place; otherwise the writer goes to
  `(point-min)`, opens a line first when `org-at-heading-p` (the dance
  `gptel-org--save-state` uses), and stores the value with
  `org-entry-put`. Replacing in place is required: `org-entry-put` at
  `(point-min)` on a notebook whose drawer sits after `#+TITLE` creates
  a second drawer and leaves the old one intact, and on a notebook whose
  only drawer is inside a heading it creates a file-level one that the
  heading's value still shadows (both verified). The writer never saves
  the buffer; the lookup steps and the `point-min` layouts above are
  pinned by ERT tests that fail if the inheritance flag drops to
  `'selective` or the file-level fallback is removed.
- `project` is the set of `.gptel-permit-rules` files along the
  directory chain from the notebook's directory up to and including
  `gptel-permit--project-root` (`(project-current)` root, else the
  notebook file's directory). Reading parses every top-level form of
  every store with `read` in a loop until end of file (comments and
  blank lines are free), with `read-circle` bound nil and no reader
  evaluation; `#.` reading is unavailable on this Emacs regardless
  (verified `invalid-read-syntax`). Parsing is cached per store file
  keyed on its modification time and invalidated when the file
  changes, keeping re-reads off the tool-call hot path while still
  picking up hand edits on the next call. The walk is nearest-first
  and stops at the root; the writer appends the printed rule plus a
  newline to the root store only, creating the file when missing, and
  never writes outside the root.
- `global` is `gptel-permit-global-rules` as today; its writer is
  `customize-save-variable`.

Origins during collection:

- Readers attest each rule they return by setting its `:origin` key —
  a plist of `:scope` plus, where meaningful, `:file` and `:heading` —
  overwriting any origin a store carried (`plist-put` on the fresh
  plist). The collector attaches `(:scope session)` and
  `(:scope global)` to session and global rules itself. Origins are
  inert during matching (only known condition and action keys are
  read), stripped by every writer before persisting, formatted into
  log lines as `scope=… file=…` / `scope=… heading=…`, and attached by
  `gptel-permit--apply-rules` to the enriched call as `:rule-origin`
  next to `:rule-scope` on a match.

Validation and error containment:

- The persisted-shape table is `gptel-permit--valid-persisted-rule-p`,
  applied only to notebook- and project-read rules. Session and global
  rules keep today's behavior: the engine's `(functionp val)` branch
  must keep working for lambdas written in init files.
- An invalid rule is skipped and logged with a line naming the scope —
  a malformed line is a user error, not an attack.
- Scope readers do not catch their own errors: a store-level read error
  propagates to `gptel-permit--apply-rules`'s existing top-level
  `condition-case`, which returns the fail-closed `(:confirm t)`.
  Catching inside a reader would risk a partially-read store being
  treated as "no rules", the wrong direction for a security control.
