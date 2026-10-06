# Design: package-split

## Context

Verified current state (file inspection + greps, this repo):

- The tree already contains six `gptel-permit*.el` files. The monolith
  exists only at the packaging level: shipping the repo's `*.el` files
  as one package is the only packaging path available today (no recipe
  files, no per-package build target, headers at `0.0.1`).
- The 2026-09-27 `decoupling` change already removed every core → module
  reference in *code*; remaining core mentions of judge/sandbox/analytics
  are docstring prose only (verified: no `defvar`/`declare-function`/
  `fboundp` call from core to a module symbol).
- The hard cross-package symbol surface is exactly five core helpers,
  all `--`-prefixed, all consumed by the module files:
  - `gptel-permit--log` — judge (≈27 uses), sandbox (≈10), analytics (3)
  - `gptel-permit--truncate-arg` — judge (3), sandbox (2), analytics (2)
  - `gptel-permit--project-root` — sandbox (4); also core-internal
  - `gptel-permit--expand-protected-dir` — sandbox (1); also core-internal
  - `gptel-permit--emit-event` — judge (2)
- The soft cross-references (all already guarded, verified):
  - judge → analytics: `(fboundp 'gptel-permit-analytics--record-decision)`
    before the programmatic-resolution record.
  - analytics → judge: `(featurep 'gptel-permit-judge)` plus bare
    `defvar` declarations of `gptel-permit-judge-model`,
    `gptel-permit--last-judge-verdict`, `gptel-permit--last-judge-rationale`.
  - analytics → sandbox: bare declaration of
    `gptel-permit-sandbox--rewritten-args`, read on the accept-time pop
    path (nil ⇒ field omitted; a `(NEW . OLD)` binding ⇒ correlation).
  - judge → sandbox: only the symbol `'sandbox` inside
    `gptel-permit--judge-action-symbols`; dispatch goes through the
    core's `gptel-permit-action-handlers`, and a miss fails closed.
- `gptel-permit-sandbox.el` binds three dynamic variables on the accept
  path (`gptel-permit--programmatic-call` core-owned;
  `gptel-permit-sandbox--rewritten-args`,
  `gptel-permit-sandbox--accepted-originally` sandbox-owned; analytics
  reads the first two's contracts). The judge binds
  `gptel-permit--programmatic-call` the same way when auto-resolving.
- Tests: twelve suites in `tests/`, all loaded by one `Makefile` target.
  Cross-suite references to *other modules' internals* occur in exactly
  two files: `tests/gptel-permit-judge-action-test.el` (stubbing
  `gptel-permit-sandbox--backend-available-p` and `--resolve-binary` for
  the `(judge sandbox …)` slot tests — deliberate integration coverage)
  and `tests/gptel-permit-analytics-test.el` (requires judge + sandbox;
  also stubs sandbox resolution variables). One core-test coupling:
  `tests/gptel-permit-rule-scopes-test.el:110` shapes a persisted rule
  around the fboundp symbol `gptel-permit-judge-safe-p`.
- Existing openspec capabilities touched: `rule-engine`,
  `rule-engine-hooks`, `sandbox`, `llm-judge`, `analytics`,
  `hook-integration` (the keymap registration text "and the sandbox
  module binds `C-c C-s`" is doc-level; no spec text names the five
  helpers — verified via grep over `openspec/specs`).

Related changes: this change *completes* `2026-09-27-decoupling`
(runtime modularity → installation modularity) and consumes its
registry/hook contracts without modifying them.

## Goals / Non-Goals

**Goals:**
- Four installable, installable-in-any-subset packages; every subset
  installs, byte-compiles, and runs.
- The core's inter-package surface is named, documented, and minimal:
  five public helpers + the already-public registry/hooks.
- "No module names a sibling in code" becomes a decidable check
  (staged per-package byte-compile), not a review promise.
- Zero behavior change on the tool-call path; zero change to stored
  state (rules, JSONL log, ids, origins).

**Non-Goals:**
- Separate repositories (decided against in the 2026-10-04 planning
  discussion: star dependency with the core at center; one repo, four
  MELPA `:files` recipes).
- Re-shaping the decoupling protocols (registry, hooks, ids, verdict
  plists, events).
- Any rename beyond the five promotions; no `--`-stripping of
  dynamic-scope variables; no obsolete-alias shims (in-repo rename, grep
  clean, zero external dependents today).
- Splitting `tests/` into per-package trees (single-repo layout keeps
  one `make test`).
- Autoload cookies on module entry points: the modules self-register at
  load (`add-to-list` into the core's registries, `keymap-set`), so
  autoloading would drag the whole file in anyway. Activation remains an
  explicit `(require …)` / `use-package` decision of the user — which is
  the trust boundary the split is about.
- A public unload function for the judge (sandbox's exists for its
  global side effects; optional nicety, tracked in tasks, not a goal).

## Decisions

### 1. One repo, four MELPA `:files` recipes

The `embark`/`embark-consult` and `magit`/`forge` precedents: recipes
differ only in `:files`. Explicit file lists, not globs — when `:files`
is given it *replaces* default exclusions, so a `("gptel-permit-sandbox/**/*.el")`
glob would sweep `tests/gptel-permit-sandbox-test.el` into the package.

```elisp
(gptel-permit           :fetcher github :repo "krvkir/gptel-permit"
                        :files ("gptel-permit.el"))
(gptel-permit-judge     :fetcher github :repo "krvkir/gptel-permit"
                        :files ("gptel-permit-judge.el"))
(gptel-permit-sandbox   :fetcher github :repo "krvkir/gptel-permit"
                        :files ("gptel-permit-sandbox.el"
                                "gptel-permit-sandbox-bwrap.el"
                                "gptel-permit-sandbox-srt.el"))
(gptel-permit-analytics :fetcher github :repo "krvkir/gptel-permit"
                        :files ("gptel-permit-analytics.el"))
```

Why the two backends ship *inside* the sandbox package, as files of it:
`gptel-permit-sandbox-bwrap.el` / `-srt.el` `require 'gptel-permit-sandbox`
and self-register classes in its registry; they must resolve at runtime.
Three layouts were considered:

- *Separate packages per backend* — rejected: install-count explosion
  with no user value; `auto` resolution would need a third package's
  `Package-Requires` to express "bwrap OR srt", which package.el cannot.
- *Backend files shipped by the core package* — rejected: re-couples the
  core (the trust-minimal unit users install first) to OS-boundary
  wrappers; a core-only install would still carry bwrap invocation code.
- *Same package, backend files listed* (chosen): the sandbox package is
  the unit that owns "OS-level boundaries"; its backends are its
  implementation detail, loaded lazily exactly as today via
  `gptel-permit--sandbox-backend-features`.

*Alternative rejected:* four Git repos. Same file contents, but each
repo re-stubs its Makefile with cross-repo `LOAD_PATH`s (the analytics
suite needs core + judge + sandbox on the path), every protocol change
becomes a cross-repo version-bump dance, and the hook protocol is
already deliberately frozen (AGENTS.org "Integration Surface") — a
star-shaped dependency graph wants one repo.

### 2. Five helpers promoted: exact symbol correspondence

The rename set — the complete hard ABI, verified by grep to be
exhaustive:

| Old (internal)                         | New (public)                    |
|----------------------------------------|---------------------------------|
| `gptel-permit--log`                    | `gptel-permit-log`              |
| `gptel-permit--truncate-arg`           | `gptel-permit-truncate-arg`     |
| `gptel-permit--project-root`           | `gptel-permit-project-root`     |
| `gptel-permit--expand-protected-dir`   | `gptel-permit-expand-protected-dir` |
| `gptel-permit--emit-event`             | `gptel-permit-emit-event`       |

- No aliases: internal-only today, grep-clean rename across the six
  files, the test files and docstrings. The promoted names join
  `rule-engine`'s public surface.
- `gptel-permit-emit-event`'s docstring gains its promotion rationale:
  it is *the* public emission entry for observer-side event sources (the
  judge uses it to fire `:judge-verdict` into the same stream with
  observer isolation guaranteed by the core).
- The other `--`-prefixed core symbols (`--apply-rules`,
  `--find-action`, `--match-rule-p`, `--enrich-tool-call`, …) stay
  private: only one in-tree *test* file goes beyond the ABI into them,
  which is a test privilege, not a contract. `gptel-permit--mint-tool-call-id`
  stays private with its format documented in `rule-engine-hooks`
  (existing), so analytics does not depend on the *symbol*, only the
  documented format.
- Elisp-wise nothing forces any of this — interned symbols are global —
  but a package named `gptel-permit-judge` calling `gptel-permit--log`
  would be dishonest signage on an ABI other people will pin. The dash
  is the only convention Elisp has, so it is used correctly.

### 3. Pinning policy: `Package-Requires` names the *hard* graph only

- `gptel-permit-judge.el`, `gptel-permit-sandbox.el`,
  `gptel-permit-analytics.el`:
  `((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.1.0"))`.
- Soft references are deliberately *not* in `Package-Requires`
  (analytics does not list judge/sandbox; judge does not list
  analytics). Their guards are the mechanism: `fboundp` /
  `(featurep …)` / bare `defvar` declarations. Consequence: an analytics
  record's judge/sandbox fields are *omitted*, never errors, when the
  module is absent — already the current behavior, now guaranteed by the
  staged tests instead of coincidence.
- A judge action spelling a `sandbox` slot without the sandbox package:
  the form dispatches on `'sandbox` through the action registry, finds
  no handler, and the engine fails closed `(:confirm t)` — the
  `decoupling` change's registry semantics, tested in
  `gptel-permit-sandbox-load-registers-action-handler` today, becomes
  the documented cross-package behavior here.
- One packaging-level wording fix this decision forces: with four
  packages there is no longer a single `gptel-permit` package whose
  files all load — `package-initialize` never loads anything, so a
  *rule* saying `:action sandbox` with the sandbox package installed but
  its file not loaded still fails closed. The README gains the "install
  ≠ load" sentence; the fail-closed path is the existing safety net.

### 4. `rule-engine-api`: the ABI capability

New spec capability in the core, so the module packages can pin the
whole contract with one `(gptel-permit "0.1.0")` and one page:

- The five helpers with argument contracts
  (`gptel-permit-log FORMAT-STRING &rest ARGS`;
  `gptel-permit-truncate-arg ARG` → string ≤ 63 chars;
  `gptel-permit-project-root` → string/nil;
  `gptel-permit-expand-protected-dir DIR &optional ROOT` → expanded
  absolute path/nil; `gptel-permit-emit-event ID TOOL-CALL TYPE PAYLOAD`
  — isolated observers, never signals, verdict-altering impossible).
- Observer-side emission contract (the judge's precedent): any module
  may mint an event TYPE inside the same `:events` vocabulary
  (`gptel-permit-events-functions`), by calling
  `gptel-permit-emit-event` with its own TYPE; observers meet unknown
  TYPEs as data. `:judge-verdict` is the first module-emitted type.
- The four dynamic-scope contracts, documented once, in one place:
  - `gptel-permit--programmatic-call` (core-owned): bound non-nil around
    programmatic accept/reject so decision capture can tell it from
    interactive approval; the core never binds it.
  - `gptel-permit--last-judge-verdict`,
    `gptel-permit--last-judge-rationale` (judge-owned, buffer-local):
    read by analytics under `(featurep 'gptel-permit-judge)`.
  - `gptel-permit-judge-model` (judge-owned): the model name recorded.
  - `gptel-permit-sandbox--rewritten-args` (sandbox-owned): the
    `(NEW-ARGS . OLD-ARGS)` alist bound around a sandboxed acceptance;
    analytics reads it to correlate rewrites.
- Everything else `--`-prefixed in the core is *not* API. A module or
  test that reaches deeper is out of contract (and `make test`-greppable
  in review).

### 5. Packaging verification as a make target, not a manual step

New target `package-build` (plus phony `test` unchanged):

1. For each of the four packages, stage its `:files` list into
   `build/<pkg>/` (byte-compilable dir).
2. Byte-compile each staged package with `LOAD_PATH = build/gptel-permit
   $(LOAD_PATH_GPTEL)` — i.e. a module sees only the *staged* core. A
   sibling `require` fails here, which is the point: it fails the CI
   build the day someone adds one, instead of failing a user's
   `package-install` later with a wrong-dependency error or, worse, a
   load-order accident.
3. Run `package-lint` per staged package if available (non-fatal when
   absent) — MELPA's own acceptance checks: non-zero version (bumped
   from `0.0.1` to `0.1.0` at this change), `Package-Requires` shape,
   `defcustom` prefix/group.
4. `package-build` runs before `test` in CI; `make test` stays the
   integration stage that loads the real tree with all modules.

`make test` layout unchanged: twelve suites, one Makefile, one `tests/`
tree. The single-suite-per-package question is re-opened only if
repositories ever split.

### 6. Test decouplings (only where coupling is accidental)

- `tests/gptel-permit-rule-scopes-test.el:110` uses the *symbol*
  `gptel-permit-judge-safe-p` as a persisted-condition shape fixture. It
  needs any fboundp symbol; it gets a test-local one. This test then
  loads with core only.
- `tests/gptel-permit-judge-action-test.el` and
  `tests/gptel-permit-analytics-test.el` keep their cross-module
  requires and stubbing: those suites *are* the integration tests for
  judge⇒sandbox and analytics⇒judge/sandbox. Their headers gain a
  "requires: <packages>" comment so the coupling reads as intent
  (analytics already declares its three requires as its first four
  forms; judge-action gains the same).
- No new dedicated "subset smoke test" files: `package-build`'s staged
  byte-compile *is* the subset check; a runtime subset ERT suite would
  re-verify what packaging already guarantees and the guards already
  implement.

### 7. Versions: `0.1.0` for all five files, pin in modules

`Package-Requires` of the three top-level module files gains
`(gptel-permit "0.1.0")` in place of the informal `(gptel-permit
"0.0.1")`. The two backend files' `Package-Requires` stay
docs-for-humans (package.el ignores non-main-file headers) — they
already name `gptel-permit`, and after this change their
`require` target ships in-package.

`make bump VERSION=x.y.z` rewrites all five `Version:` headers in one
command; four-on-one-repo versioning otherwise moves in lockstep (the
registry/hooks/docstring contract of `rule-engine-api` is the thing the
pins actually track).

## Risks / Trade-offs

- **Recipe split window on MELPA.** Until all four recipe PRs merge, a
  user tracking MELPA gets the old single package; a stale single install
  alongside a fresh module one would collide on file names. Mitigation:
  submit all four recipes in one PR; bump the split release only after
  they land.
- **`(defvar gptel-permit-sandbox--rewritten-args)` defines a
  sandbox-prefixed variable in an analytics-only install.** Harmless
  (nil value, no other toucher) and unavoidable without a runtime
  contract file that would just move the problem; acknowledge with a
  docstring line and the ABI list (decision 4).
- **Staged byte-compile depends on repository layout discipline** (an
  out-of-tree fixture could accidentally see a sibling). The staging
  script copies, never symlinks, and CI runs it from a clean worktree.
- **Docstring module-name mentions survive in the core** (`:action`
  docstring mentions the sandbox/judge as registry examples). That is
  prose, not code — the staged byte-compile cannot see it, and the
  honesty it buys in `M-x describe-variable` is worth the words.
- **Lockstep versioning costs**: four packages bump together even when
  one changed. Small now (one Makefile command); revisit if the modules
  ever develop independent release cadences.

## Migration Plan

1. Rename pass + header bumps + ABI section (no behavior change; full
   suite passes with renamed symbols).
2. `package-build` target lands; the twelve suites plus four staged
   builds are the new green bar.
3. Recipe PRs to melpa/melpa (all four in one PR) merged *before* the
   release tag; README/AGENTS/specs updated in the same series.
4. Users migrate by editing their `use-package` blocks (the README's
   new installation matrix is drop-in copy-paste for every subset).
   Stored state needs no migration: rules, `.gptel-permit-rules`,
   notebook properties, the analytics JSONL all keep their formats and
   files; ids keep their format.
5. Rollback at any point before the recipe merge: revert commits; after
   it, the old single-package install still functions (names are
   forward-compatible); the four-package recipes may land whenever.

## Open Questions

- Should `gptel-permit-truncate-arg`'s byte budget (30+3+30) become an
  option analytics can widen per-event? Deferred: analytics already
  calls it with its own truncation policy in mind; widening is additive.
- A `gptel-permit-judge-unload-function` mirroring the sandbox's?
  Optional nicety; tracked in tasks (3.4), not a design decision.
- One-PR recipe landing is assumed; if MELPA's maintainers prefer four
  separate PRs, the risk only lengthens the window, not the design.
