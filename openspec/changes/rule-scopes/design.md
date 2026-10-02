# Design: rule-scopes

## Context

See proposal.md — Why. The relevant current state, verified:

- `gptel-permit--find-action` (`gptel-permit.el:532`) is the only
  precedence decision in the package:
  `(dolist (rule (append gptel-permit-rules gptel-permit-global-rules)) ...)`,
  first match wins. It emits `:rule-match` from inside the loop, on the
  first matching rule.
- `gptel-permit-rules` (`:148`) is a `defvar-local`; the wizard's writer
  is `(push rule gptel-permit-rules)` (`:663`).
- The engine runs in the notebook buffer: gptel's `gptel--handle-pre-tool`
  (`gptel.el:1519`) does `(with-current-buffer buffer ... (run-hook-wrapped
  'gptel-pre-tool-call-functions ...))`, so `buffer-file-name`,
  `default-directory`, and the major mode are all the notebook's while
  `gptel-permit--apply-rules` executes. No path threading is needed.
- `gptel-permit--project-root` (`:228`) already means exactly "project
  root, else the notebook's directory": `(project-current)` →
  `project-root`, else `(file-name-directory (buffer-file-name))`.
- gptel persists per-notebook state in two different ways depending on
  the notebook format, and both are reachable from a `gptel-permit`
  command:
  - Org: `gptel-org--save-state` writes `GPTEL_BOUNDS` with
    `org-entry-put (point-min)` as a `prin1`-ed form; `gptel-org--restore-state`
    reads it back with `(read (org-entry-get (point-min) "GPTEL_BOUNDS"))`.
    Verified round-trip for a rules-shaped value.
  - Markdown: `gptel--save-state` uses
    `(add-file-local-variable 'gptel--bounds ...)`; `gptel.el:410` gives
    the variable a `safe-local-variable` property (`listp`). The buffer's
    `Local Variables:` block is written by `files-x`, autoloaded.
    Verified: a markdown file-local `gptel-permit-notebook-rules` value
    is applied on visit when the property is registered, and Emacs
    refuses to apply it when it is not.
- Reader safety, verified on Emacs 31.1: `#.` is
  `(invalid-read-syntax "#.")` unconditionally (`read-eval` is not even
  bound), `read-circle` is t by default, and the plain `read` of a
  commented multi-form string returns the forms in order.
- Org property lookup is not uniform, measured on Org 9 / Emacs 31.1:
  - `gptel-org--entry-properties` (`gptel-org.el:548`) reads every
    `GPTEL_*` configuration property with
    `(org-entry-get (or pt (point)) prop 'selective)` — i.e. gptel's own
    per-notebook configuration is read at *point*, per entry, with no
    inheritance.
  - `org-use-property-inheritance` defaults to nil, so `'selective` never
    inherits an arbitrary property; `org-entry-get` with `t` inherits and
    sets `org-entry-property-inherited-from`.
  - `org-entry-get` at `(point-min)` with either argument **misses** a
    `:PROPERTIES:` drawer that follows a keyword line such as `#+TITLE:`
    (both it and `org-property-values` return nil), while a drawer placed
    before any keyword is found. `gptel-org--restore-state` gets away with
    `(org-entry-get (point-min) "GPTEL_BOUNDS")` only because its own
    writer puts the drawer at `(point-min)` before any preamble, via the
    `(when (org-at-heading-p) (org-open-line 1))` dance at
    `gptel-org.el:677`.
  - `org-entry-put` at `(point-min)` on a notebook that already has a
    file-level drawer *after* a keyword line creates a second
    `:PROPERTIES:` block and leaves the first intact; on a notebook whose
    only drawer is inside a heading it creates a file-level one that the
    heading's value still shadows.

## Goals / Non-Goals

**Goals:**
- One precedence policy, expressed once, in the registry's order.
- Every scope's storage in the format that already belongs to that
  context: the notebook's own file for the notebook scope, the project
  root for the project scope, the config for the global scope, the buffer
  for the session scope.
- Persisted rules are inert data. Reading a store must never evaluate
  code, and a store that cannot be read must never auto-run a tool.
- Zero behavior change when no persisted rules exist.

**Non-Goals:**
- Changing rule *matching* (conditions, arg-groups, predicates,
  normalization).
- Changing the hook pipeline, the verdict contract, or the action
  registry.
- A user interface for editing project or notebook stores outside the
  wizard (no `customize` group for a file, no dedicated editing command
  beyond persistence-on-create).
- Encrypting, signing, or locking stores.
- Synchronizing a store across machines.

## Decisions

### 1. Scope registry, not a hardcoded `append`

`gptel-permit-rule-scopes` is an ordered alist:

```elisp
(defvar gptel-permit-rule-scopes
  '((session  :reader gptel-permit--read-session-rules
              :writer gptel-permit--write-session-rule)
    (notebook :reader gptel-permit--read-notebook-rules
              :writer gptel-permit--write-notebook-rule)
    (project  :reader gptel-permit--read-project-rules
              :writer gptel-permit--write-project-rule)
    (global   :reader gptel-permit--read-global-rules
              :writer gptel-permit--write-global-rule)))
```

`gptel-permit--find-action` becomes a walk over this alist, and the scope
symbol of the matching rule is carried out of it. This follows the house
pattern already used for `gptel-permit-action-handlers`,
`gptel-permit-sandbox-backends`, and `gptel-permit-sandbox-adapters`:
user-visible, inert, symbol-keyed data.

*Alternative rejected:* four `defcustom`s and a fixed order in the engine.
It buries the precedence in the engine and gives a third-party scope
(e.g. a "workspace" scope above a project) no way in.

### 2. Readers return rule lists; the engine never knows a format

Each reader is a zero-arg function called in the session buffer, which is
already the notebook buffer. This is what keeps org, markdown, project
file, and defcustom knowledge out of the engine and out of each other.
A reader that has no storage in the current context returns nil.

Readers also attest each rule they return by setting its `:origin` key —
a plist of `:scope` plus, where the scope has several possible sources,
`:file` and `:heading` (the project reader names its store file; the Org
reader names the heading or marks the file level; the markdown reader
names the notebook file) — overwriting any origin a store tried to
carry. The collector attaches `(:scope session)` and `(:scope global)`
itself. Origins are a log/introspection concern only: inert during
matching (matching reads only the rule's own keys), stripped by every
writer, never read by analytics (which keeps its coarse `scope` field),
and surfaced as the `:rule-origin` annotation next to `:rule-scope` on a
matched call (decision 7).

### 3. Notebook scope: two formats, one scope

The scope branches on the notebook's major mode, not on the file
extension:

- `(derived-mode-p 'org-mode)` → `GPTEL_PERMIT_RULES` property.
- otherwise (markdown, text) → the `gptel-permit-notebook-rules`
  file-local variable.

Org reading is a two-step lookup (verified behavior, not guesswork):

1. `org-entry-get` at `(point)` with inherit `t` — the current entry's
   value or the nearest ancestor heading's. This is what buys
   per-heading rules (comment 4 of the exploration): it is one argument,
   not a feature.
2. otherwise the first `GPTEL_PERMIT_RULES` property line before the
   first headline — the file-level drawer.

Step 2 exists because `org-entry-get` at `(point-min)` does not see a
drawer that follows a keyword line. Measured on Emacs 31.1 + Org 9:
with the layout `#+TITLE: …` / `:PROPERTIES:` / `:GPTEL_PERMIT_RULES: V`
/ `:END:`, `org-entry-get` at `(point-min)` returns nil and so does
`org-property-values`; the same drawer placed before the keyword is
found. Since gptel's own `GPTEL_BOUNDS` write happens at `(point-min)`
after the `org-open-line` dance and therefore lands *before* any
preamble, the package's own writer creates a layout step 1 happens to
find — but a user-authored or hand-edited notebook will not, and the
reader must not depend on the writer's layout.

The writer always targets the file-level drawer and, when one already
exists, edits that line in place; the list it writes is built from the
file-level value alone, so a heading override is neither copied into the
notebook-wide list nor silently promoted. Measured: `org-entry-put` at
`(point-min)` on a notebook whose drawer sits after `#+TITLE` creates a
*second* property block and leaves the old one intact; on a notebook
whose only drawer is inside a heading it creates a file-level one that
the heading's value then shadows. Both are wrong for "persist a notebook
rule", so the writer replaces the existing line, and falls back to
`org-entry-put` (with the `org-open-line` dance) only when there is no
file-level line yet.

*Alternative rejected:* inventing a YAML/TOML front-matter block for `.md`
notebooks. gptel already stores markdown notebook state in the file-local
variable list, so a second, parallel convention would be a second thing
to teach, parse, and get wrong; the file-local list is also the mechanism
Emacs already marks safe or unsafe. This supersedes the exploration's
"invent a YAML convention" preference with the stronger argument that
gptel's own markdown mechanism is the file-local list, not front matter.

*Alternative rejected:* an Org `#+BEGIN_SRC elisp` block for multi-line
readability. The user accepted single-line values (comment 3), and the
property drawer is the mechanism gptel itself uses (`GPTEL_BOUNDS`), so
the scope stays uniform with the rest of the notebook.

### 4. Project scope: one printed form per line in `.gptel-permit-rules`

File at `(gptel-permit--project-root)`. Reader: `(read (current-buffer))`
in a loop until `end-of-file`, with `read-circle` bound to nil, collecting
forms. Comments and blank lines are free — verified. Writer: append
`(prin1-to-string rule)` plus a newline, creating the file when missing.

A store may live in /any/ directory on the chain from the notebook's
directory up to and including the project root, and the reader walks the
whole chain nearest-first (the closest store's rule decides; stores
further up fill where the closer ones are silent). The walk stops at the
root: nothing above it is read, so a store in `~/` cannot govern a
project below it — cross-project policy belongs to the global scope.
This policy — "nearest decides, broader fills" — is a deliberate
divergence from dir-locals, measured here first: `dir-locals-find-file`
resolves innermost-exclusively (the search stops at the first
`.dir-locals.el` walking upward, so a subfolder file silently suppresses
the ancestor file entirely). Exclusive would be wrong for policy: adding
a subfolder store with one narrow `allow` rule would silently discard the
root store's `ask`/`deny` rules for the same call, and a permission
system that quietly deletes safety rules while being edited loses. Union
with nearest-first ordering matches `.gitignore`/`.editorconfig` instead,
and it makes the package's precedence law uniform: nearest decides,
broader fills, everywhere (Org: heading over file drawer with the
broader value still applying to subtrees that set none; scopes: session →
notebook → project → global; project: inner store over outer store).

`read` is safe against `#.` on this Emacs (verified: unconditional
`invalid-read-syntax`), and binding `read-circle` nil removes the
circular-structure vector from the `files.el` playbook.

Caching is keyed per store file on its modification time (an alist of
`file → (mtime . rules)`, since a chain can hold several stores), so the
common path (one project, many tool calls per turn) does not re-read per
call, while an edited store, wherever it sits, is picked up on the next
call.

*Alternatives rejected:* `.dir-locals.el` (native and auto-applying, but
it is Emacs's file for Emacs's settings, its values flow through
`hack-local-variables` and the dir-locals confirmation machinery, and a
package writing into it collides with whatever the project already keeps
there); JSON via `json-encode`/`json-read` (no comments, and rules are
Lisp plists with keywords and function symbols, which JSON cannot carry).
A Lisp file is the one format that is already the rules' own
representation.

### 5. Persisted rules are validated as data

A `gptel-permit--valid-persisted-rule-p` predicate accepts a rule only if
it is a non-empty plist with keyword keys and every condition value is a
string, a predicate keyword, or a symbol naming a function. Lambda and
other cons-shaped condition values are rejected and logged. Session and
global rules skip validation: they are the user's own configuration, and
today's `(functionp val)` branch in `gptel-permit--dispatch-condition`
must keep working for lambdas written in init files.

This is the "data, not code" line from the AGENTS.org contract: a cloned
repository can supply a `.gptel-permit-rules`, so a persisted condition
value must not be a form the reader can turn into a callable. A symbol
naming a function still is one, and that is deliberate: naming a function
is not the same as embedding code, and it keeps the judge-style callable
idiom available in persisted stores.

### 6. Reader errors fail closed by not being caught

Readers do not wrap their work in `condition-case`. `gptel-permit--apply-rules`
already has the top-level `condition-case` that turns any error into
`(:confirm t)`. Catching inside a reader would risk a partially-read store
being treated as "no rules", which is exactly the wrong direction for a
security control.

The one deliberate exception is per-rule validation: a single invalid rule
is skipped with a log line rather than aborting the store, because a
malformed line is a user error, not an attack — and the fail-closed
default for *matching* (defer, then the tool's own `:confirm`) is already
safe.

### 7. Scope and origin are metadata on the tool call plus one log line

The matcher attaches `:rule-scope` to the enriched tool call at the moment
it decides a match, before emitting `:rule-match`, and the matched rule's
reader-attested origin (decision 2) as `:rule-origin` beside it. Because
`gptel-permit--emit-event` passes the same plist to observers, the scope
and origin are visible to analytics with no signature change, and the event
payloads (`nil`, the action symbol, `(ACTION . VERDICT)`) are untouched. The
analytics observer reads `:rule-scope` off the tool call for its
`rule-match` and `verdict` records, which is one added `scope` field; the
finer origin (which store file, which heading) lives in the log.

*Alternative rejected:* adding a fifth argument to the events hook. That
reaches into `rule-engine-hooks`'s uniform callback signature and every
observer for data that rides the call naturally.

*Note on plist aliasing:* `plist-put` mutates the plist it is given and
returns the head, so annotating the enriched call must be written as a
rebinding (`(setq enriched (plist-put enriched :rule-scope scope))`), and
the enriched call must not be a shared tail of a caller's plist. Both are
true of the current construction (`append` of a fresh list in
`--enrich-tool-call`), but it is the kind of detail that must not be
"simplified" later.

### 8. The wizard's scope question is last, defaulting to session

`gptel-permit-add-rule` gains one `completing-read` after the action
prompt, over the scope symbols of the registry, defaulting to `session`.
The rule is pushed to `gptel-permit-rules` only for the `session` scope;
for any other scope it is handed to that scope's `:writer`, and on writer
failure it falls back into `gptel-permit-rules` so the user's decision is
not lost. The global writer goes through `customize-save-variable`, which
is the supported way to update a defcustom's running value and its saved
value at once.

Persisting into a non-session scope and *also* pushing to
`gptel-permit-rules` would be worse than redundant: since session is the
first scope, every later re-match of the call would report scope `session`,
so the log line and the analytics `scope` field would stop naming the scope
the user chose. The wizard does not need the session copy to resolve the
*pending* calls either — it calls `gptel--accept-tool-calls` /
`gptel--reject-tool-calls` directly on them, it does not re-run matching.
And the three non-session stores are readable immediately after the write
(the Org property is in the buffer, the markdown variable is buffer-local,
the project file's cache entry is refreshed by the writer), so the next
tool call already sees the rule in its own scope.

*Alternative considered:* always keep a session copy for prompt
resolution. Rejected for the reporting reason above; the only place a
session copy is justified is writer failure, where it is the fallback.

### 9. Project rules are trusted like `.dir-locals.el`, and can be turned off

`.gptel-permit-rules` is read without a confirmation prompt — a prompt on
the tool-call path would arrive at the worst possible moment, and
`read` of inert data is strictly weaker than `dir-locals`' value
assignment. `gptel-permit-project-rules-enabled` (default t) is the
supported way to say "my projects' repositories do not get to
auto-approve anything"; disabling it makes the project scope contribute nothing.

## Risks / Trade-offs

- **Repository-supplied policy auto-approves tool calls.** A cloned repo
  — or, with the chain, any working directory inside one, though nothing
  above the root — with a `.gptel-permit-rules` can allow its own tool
  calls, exactly as a repo's `.dir-locals.el` can set variables. Mitigations: the scope is
  opt-out; readers never evaluate code; validation rejects form-shaped
  conditions; a session rule (including one just made via the wizard, which
  defaults to session) overrides it; the log line and the analytics `scope`
  field always name the authorizing scope.
- **A malformed project store fails every call closed** (`(:confirm t)`),
  because reader errors propagate. That is the intended direction — the
  alternative (treating an unreadable store as empty) would let the global
  scope's `:action ask` default hide a store the user believes is in effect.
  The error is logged; the fix is to repair the store.
- **Silent divergence between the wizard's session copy and the store.**
  Editing `.gptel-permit-rules` by hand after adding a session rule means
  two rules for one decision. Session rules win by design, and the log's
  scope line makes it visible.
- **`org-entry-get` inheritance can surprise.** With inherit `t`, a
  file-level value reaches every heading; a heading value silently wins
  below it. The exploration accepted this as "for free" behavior, but it is
  a footgun for a user who sets a value at file level, edits a heading's
  value, and forgets. Mitigation: document the nearest-value-wins rule in
  the README's scope table, and keep the wizard's notebook writes at file
  level so a rule created through the UI never lands in a subtree by
  accident.
- **Markdown notebooks depend on `enable-local-variables`.** A user who
  sets it to nil gets no markdown notebook scope at all. Documented; the
  reader simply returns nil (the variable was never set).
- **Caching hides an edit made during the same millisecond.** The mtime
  cache is per store file (the project chain can hold several); worst
  case an edit takes effect one tool call later. Same trade-off as
  dir-locals' own `dir-locals-directory-cache` mtime validation, and it
  keeps reading off the tool-call hot path.

## Migration Plan

Additive; no stored user state migrates. Existing session and global rules
keep working, and a user with no persisted stores sees an unchanged engine.
Users who had been adding rules and losing them on buffer death can now
answer the wizard with `notebook` or `project`; `gptel-permit-rules`
remains buffer-local, so nothing that used to work stops working.

Rollback is config-only: remove the non-session entries from
`gptel-permit-rule-scopes` (or set `gptel-permit-project-rules-enabled`
nil), and the engine's collection reverts to session plus global. The
stored files are inert and harmless if left on disk.

## Open Questions

- Per-heading rules are a side effect of inherit `t` and are documented
  rather than designed. If a user wants heading rules to be *explicit*
  (e.g. only under a `GPTEL_PERMIT_SCOPE` marker), that is a follow-up
  decision about the notebook format, not about this change.
- A future "workspace" scope above `project` needs no engine work; the
  registry accepts it. Not specified now.
- Whether the analytics report should break auto-allow rates down by
  scope is a reporting question; the field will be present and folding it
  is additive.
