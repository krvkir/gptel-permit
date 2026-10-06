# Proposal: package-split

## Why

All code already lives in six `gptel-permit*.el` files, but packaging
ships all of them as one package, so no user can install the rule engine
without also installing the judge's request plumbing, the sandbox
boundary machinery and the analytics logger into their `~/.emacs.d` —
including code paths they never activate and may prefer not to carry at
all (for example a user who will not run analytics code they do not
trust, or a judge-averse user who wants the sandbox without the request
path). The three optional modules are *runtime-optional* — every module
integrates through the core's registry/hooks and every missing-module
path fails closed — but packaging makes them *installation-mandatory*.
The split also unblocks independent develop-test-verify cycles: today
`make test` loads twelve suites against the whole tree, and nothing
verifies that a module byte-compiles without its siblings.

## What Changes

- **Four packages instead of one**, from one monorepo (MELPA per-package
  `:files` recipes; `embark`/`embark-consult` precedent):
  - `gptel-permit` — `gptel-permit.el` only: the rule engine, validation,
    the four rule scopes, ids, the action registry, the engine hooks.
  - `gptel-permit-judge` — `gptel-permit-judge.el`: the `judge` condition
    callable, the `judge` action and its async machinery.
  - `gptel-permit-sandbox` — `gptel-permit-sandbox.el` plus its backend
    modules `gptel-permit-sandbox-bwrap.el` and
    `gptel-permit-sandbox-srt.el` (they `require` the sandbox feature and
    self-register in its registry; lazy loading must keep working, so
    they ship together).
  - `gptel-permit-analytics` — `gptel-permit-analytics.el`.
- **Dependency edges stay minimal**: judge, sandbox and analytics depend
  only on `gptel-permit` (+ gptel), /not on each other/ — their three
  cross-references (judge⇒analytics record-decision, analytics⇒judge
  buffered state, analytics⇒sandbox rewritten-args) are `fboundp`-
  guarded or `(featurep …)`-verified and stay unlisted in
  `Package-Requires`. A judge action whose `sandbox` slot has no module
  installed resolves through the engine's unregistered-action path
  (`(:confirm t)`).
- **Five core helpers promoted to public names** (`--` stripped, no
  aliases): `gptel-permit-log` ← `gptel-permit--log`,
  `gptel-permit-truncate-arg` ← `gptel-permit--truncate-arg`,
  `gptel-permit-project-root` ← `gptel-permit--project-root`,
  `gptel-permit-expand-protected-dir` ← `gptel-permit--expand-protected-dir`,
  `gptel-permit-emit-event` ← `gptel-permit--emit-event`. These are the
  only private core symbols another package hard-references today; after
  the split that becomes an inter-package ABI, so the names lose their
  dash. Everything else `--`-named stays internal.
- **A new `rule-engine-api` capability** in the core's specs: the module
  interface — the five helpers, the action registry, the three engine
  hooks, the tool-call id format, and the four documented dynamic-scope
  contracts (the programmatic-resolution flag, the judge's per-call
  state, the sandbox rewritten-args alist) that optional modules read
  or bind.
- **New make target** `package-build` (staged, per-package byte-compile
  with only the staged core on the load path) turning "no package names a
  sibling" into a decidable CI check, plus `package-lint` per staged
  package.
- **Docs**: README gains a four-package installation matrix and changes
  "part of the package, loaded on demand" wording; AGENTS.org gains the
  packaging section and the ABI list.
- **Version bumps**: all five files to `0.1.0`; the three module files'
  `Package-Requires` pin `(gptel-permit "0.1.0")`.

Non-goals: changing any protocol from the `2026-09-27-decoupling` change
(registry, hooks, ids, verdicts); moving files to separate repos;
renaming or reshaping private symbols beyond the five promotions;
splitting tests into per-package trees; a public unload mechanism for the
judge; `;;;###autoload` cookies on module entry points (the modules
self-register at load, so autoloading them would load the whole file —
activation stays `(require …)` / `use-package`).

## Capabilities

### New Capabilities
- `rule-engine-api`: the core's inter-package ABI — the five public
  helpers with their argument contracts, the events-hook emission
  contract for observer-side event sources, and the four dynamic-scope
  variables optional modules may rely on.

### Modified Capabilities
- `rule-engine`: the five helpers are renamed public; the core gains no
  module knowledge (docstring prose names modules, code never does) —
  unchanged matching, scopes, validation and fail-closed semantics.
- `sandbox`: unchanged behavior; its Package-Requires now documents the
  core pin; the backend modules ship in the same package as the sandbox
  core.
- `llm-judge`: unchanged behavior; its `Package-Requires` now documents
  the core pin; the analytics call in the programmatic resolution path is
  confirmed soft (`fboundp`-guarded, no hard dependency).
- `analytics`: unchanged behavior; all cross-module reads
  (`(featurep 'gptel-permit-judge)`, the sandbox binding) stay
  guarded/declared and yield omitted fields, never errors, in every
  installed-subset configuration.

## Impact

- **Code**: `gptel-permit.el` (five renames + ABI docstring section),
  `gptel-permit-judge.el` / `gptel-permit-sandbox{,-bwrap,-srt}.el` /
  `gptel-permit-analytics.el` (rename fan-in, header bumps, one
  `defvar`-declaration docstring note), ≈40 renamed-symbol uses overall;
  no logic edits.
- **Rule matching / hook pipeline**: unchanged. Every verdict path,
  event order, and fail-closed guarantee of `judge-async-action` (as
  landed) and `rule-scopes` is preserved; no test's assertions change
  except symbol names.
- **Packaging**: MELPA recipes replace the single-package install;
  `package-install-file` of the repo dir would now mis-package — the
  staged `package-build` target becomes the only supported install
  verification. `make test` is unchanged (one `tests/` tree, all suites).
- **Failure modes**: unchanged in every direction, now *decidable* per
  installed subset: core alone; core+sandbox; core+judge (a `(judge
  sandbox …)` action without the sandbox package → `(:confirm t)`);
  analytics with neither (judge/sandbox fields omitted from events);
  every subset byte-compiles green under `package-build`.
- **Public API / stability surface**: the five promoted names join
  `gptel-permit-action-handlers` and the three hooks as the documented
  ABI the module packages pin with `Package-Requires`; the four
  dynamic-scope contracts are documented in one place.
- **Migration for users**: configuration snippets change (install
  matrices per module); stored state (rules, JSONL log, ids) migrates
  without any action — same formats, same files.
