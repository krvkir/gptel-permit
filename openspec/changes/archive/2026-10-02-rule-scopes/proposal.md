# Proposal: rule-scopes

## Why

Rules live in exactly two places today: `gptel-permit-rules`, a
`defvar-local` that dies with the buffer, and `gptel-permit-global-rules`,
a defcustom edited by hand. The interactive rule wizard
(`C-c C-b`, `gptel-permit-add-rule`) pushes into the first, so every
recurring decision — "let the LLM read this package", "let it run
`make test` here" — must be re-created from scratch whenever the notebook
buffer is closed. The cost of the feature (a rule) is amortized over one
buffer's lifetime, which is exactly the wrong unit.

The engine already has the shape needed for more scopes: one ordering
point (`gptel-permit--find-action`, a `dolist` over
`(append gptel-permit-rules gptel-permit-global-rules)`), one storage
key (a list of rule plists), and one writer (`push rule
gptel-permit-rules`). Adding persistence is adding storage backends and
one scope question, not redesigning matching.

## What Changes

- **Four rule scopes, checked most-specific first**: `session`
  (buffer-local, as today), `notebook` (persisted in the notebook file),
  `project` (persisted in the project root), `global` (the config
  defcustom, as today). First match wins across the scopes, so a session
  rule still overrides everything.
- **A scope registry.** New public ordered alist
  `gptel-permit-rule-scopes` mapping a scope symbol to a plist of
  `:reader` (returns that scope's rule list) and `:writer` (persists one
  rule). The engine iterates the registry in order; the core no longer
  hardcodes "session then global". A scope with no readable storage
  contributes nothing.
- **Notebook scope, in the notebook's own format.** Org notebooks store
  the rules in a `GPTEL_PERMIT_RULES` property: a value in the entry
  under point or its nearest ancestor heading wins (per-heading rules for
  free), and otherwise the file-level drawer applies — looked up
  explicitly, because `org-entry-get` misses a drawer that follows a
  keyword line such as `#+TITLE:`. Markdown notebooks use the mechanism
  gptel itself uses for markdown: a `gptel-permit-notebook-rules` entry
  in the standard `Local Variables:` block at the end of the file,
  written with `add-file-local-variable` and given a
  `safe-local-variable` property so visits do not prompt.
- **Project scope.** `.gptel-permit-rules` files — one printed rule
  plist per line, `;` comments allowed — read from every directory on
  the chain from the notebook's directory up to the project root
  (`gptel-permit--project-root`: `(project-current)` root, else the
  notebook's directory), nearest store first: the closest store's rule
  decides, broader stores fill where it is silent, and the walk stops
  at the project root (nothing above it is read; cross-project policy
  is the global scope's business). Read with `read` in a loop,
  `read-circle` bound to nil, no reader evaluation; cached per file by
  modification time.
- **Global scope, writable.** The wizard can persist into
  `gptel-permit-global-rules` via `customize-save-variable`, and the
  wizard's scope question is the last question, defaulting to `session`
  (today's behavior). A non-session answer routes the rule to that scope's
  writer only — no session copy, so the reported scope is the one the
  user chose; a writer failure falls back to the session copy.
- **Persisted rules are data, not code.** Rules read from notebook and
  project storage are validated: a rule that is not a plist of keyword
  keys, or whose condition value is not a string, a predicate keyword,
  or a named function symbol, SHALL NOT participate in matching
  (lambda/code-shaped condition values are rejected and logged).
- **Scope is reported**: the log chain names the scope that matched, the
  enriched tool call carries `:rule-scope` from the moment the match is
  decided, and the analytics `rule-match`/`verdict` events gain a `scope`
  field.
- **Rule origins are recorded.** Every collected rule carries an origin —
  its scope plus, where the scope has several possible sources, the
  exact one (project store file, Org heading or file level, notebook
  file) — attached at read time, inert during matching, stripped by
  writers, surfaced in the log and as `:rule-origin` on the tool call,
  so a surprising verdict can be traced to the exact rule file or
  heading, not just the scope.
- **Project rules are trusted like `.dir-locals.el`** — a cloned
  repository can ship `.gptel-permit-rules`. New defcustom
  `gptel-permit-project-rules-enabled` (default `t`) turns the project scope off
  entirely for users who do not want repository-supplied policy to be
  read.
- **Incidental correction.** The `hook-integration` "Keybinding"
  requirement names `gptel-permit-confirm-or-add-rule`, a function that
  does not exist (the command is `gptel-permit-add-rule`). The modified
  block fixes the name.

## Capabilities

Scopes are a property of rule evaluation, so there is no separate
`rule-scopes` capability: the scopes and their storage behavior belong to
`rule-engine`, the creation flow to `hook-integration`.

### Modified Capabilities
- `rule-engine`: "Match Algorithm — First Match Wins" becomes four-scope
  and most-specific-first; "Diagnostic Logging" additionally reports the
  matching scope and the exact source of the matched rule. New added
  requirements cover the scopes themselves —
  the scope configuration, the session / notebook / project / global
  scopes (project stores read nearest-decides/broader-fills over the
  directory chain), rule-origin introspection, persisted-rule
  validation ("data, not code"), fail-closed store errors, and the
  project-rule trust opt-out.
- `rule-engine-hooks`: new requirement — the scope that produced a match
  is observable on the enriched tool call (`:rule-scope`) from the
  `:rule-match` decision point onward; existing event payloads are
  unchanged.
- `analytics`: `rule-match` and `verdict` events carry the matched rule's
  `scope`, so an auto-allow can be audited back to the scope that
  authorized it.
- `hook-integration`: "Keybinding" gains the scope question in the rule
  wizard (last question, default `session`, no duplication into the
  session on non-default answers, session fallback on storage failure)
  and names the correct command.

## Impact

- **Hook pipeline**: `gptel-pre-tool-call-functions` registration,
  ordering, and the verdict contract are untouched. Only the body of
  `gptel-permit--find-action` changes: it iterates the scope registry
  instead of a two-element `append`. The engine's existing top-level
  `condition-case` already turns any reader error into the fail-closed
  verdict `(:confirm t)`, so a hostile or broken store cannot auto-run a
  tool; readers deliberately do not catch their own errors.
- **Match behavior**: for a call that previously fell through to a global
  rule, a notebook or project rule now matches first. This only happens
  once a user creates such a rule; with no persisted rules the added
  scopes contribute nothing and behavior is byte-identical to today. The wizard
  default keeps new rules in the session scope.
- **Code**: `gptel-permit.el` (scope registry, three new readers, one new
  writer, persisted-rule validation, `--find-action`, the wizard's scope
  question, two defcustoms, log line). No module-specific code; the
  sandbox, judge, and analytics modules never name a scope.
- **Tests**: `tests/gptel-permit-rule-engine-test.el` (registry ordering,
  cross-scope precedence), new `tests/gptel-permit-rule-scopes-test.el`
  (readers/writers per format, validation table, mtime cache,
  fail-closed reader errors), `tests/gptel-permit-rule-engine-hooks-test.el`
  (`:rule-scope` on the call at the `:rule-match` point),
  `tests/gptel-permit-analytics-test.el` (scope field and legacy records
  still folding), `tests/gptel-permit-hook-integration-test.el` (wizard
  scope prompt and writer dispatch).
- **Docs**: README gains a "Rule scopes" section with the precedence
  table, the org property / markdown Local Variables / project file
  formats, and the trust caveat; `gptel-permit-rules` and
  `gptel-permit-global-rules` docstrings cross-reference the scopes.
- **Dependencies**: none new. Org is used only under `org-mode` buffers
  with `(require 'org nil t)`; markdown support needs nothing beyond
  `add-file-local-variable` from `files-x`, which is autoloaded.
