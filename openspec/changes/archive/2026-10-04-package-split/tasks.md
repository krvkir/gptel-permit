# Tasks: package-split

## 1. Rename pass (no behavior change)

- [x] 1.1 Rename in `gptel-permit.el`: `gptel-permit--log` → `gptel-permit-log`, `gptel-permit--truncate-arg` → `gptel-permit-truncate-arg`, `gptel-permit--project-root` → `gptel-permit-project-root`, `gptel-permit--expand-protected-dir` → `gptel-permit-expand-protected-dir`, `gptel-permit--emit-event` → `gptel-permit-emit-event` (definition + all in-file uses + docstring `defvar`s untouched otherwise)
- [x] 1.2 Rename fan-in in the five module files: judge (log ×≈27, truncate ×3, emit-event ×2), sandbox (log ×≈10, truncate ×2, project-root ×4, expand-protected-dir ×1), analytics (log ×3, truncate ×2)
- [x] 1.3 Update docstring cross-references mentioning the old names (`--emit-event`, `--truncate-arg`, `--project-root`, `--expand-protected-dir`) across all files
- [x] 1.4 Grep-clean check: `grep -RnE "gptel-permit--(log|truncate-arg|project-root|expand-protected-dir|emit-event)" --include='*.el' .` returns nothing outside archived org notes; run full `make test` and batch byte-compile of all six files — green, no new warnings

## 2. Headers, ABI docs, specs

- [x] 2.1 Bump all five main-file headers to `Version: 0.1.0`; set the three module files' `Package-Requires` to `((emacs "29.1") (gptel "0.9.9") (gptel-permit "0.1.0"))`
- [x] 2.2 Add the `;;; Module interface` section to `gptel-permit.el` after the engine hooks: lists the five public helpers, the action registry, the three hooks, the id format pointer to `rule-engine-hooks`, and the four dynamic-scope contracts (`gptel-permit--programmatic-call`, judge's two state vars, `gptel-permit-sandbox--rewritten-args`), with a "everything else `--`-prefixed is not API" sentence
- [x] 2.3 Extend `gptel-permit-emit-event`'s docstring with the observer-side emission contract (judge precedent: `:judge-verdict`); add the one docstring line to analytics' `(defvar gptel-permit-sandbox--rewritten-args)` declaration noting it is an ABI declare, inert without the sandbox
- [x] 2.4 Add `:package-version '("gptel-permit" . "0.1.0")` markers to the three module `defgroup`s; optional: `gptel-permit-judge-unload-function` mirroring the sandbox's unload (remove hook, registry entry, keymap binding)
- [x] 2.5 Merge the deltas in `specs/` into `openspec/specs/`: new `rule-engine-api/spec.md` (ADDED), MODIFIED requirements merged into `rule-engine`, `llm-judge`, `sandbox`, `analytics`; re-read merged specs for contradictions; archive notes for `hook-integration`'s "sandbox module binds C-c C-s" wording if the new packaging section makes it ambiguous

## 3. Packaging verification

- [x] 3.1 Add `.gitignore` entries for noise (`*.elc`, `build/`, org backup files, stray patch/txt artifacts) so staged/tooling runs see a clean tree
- [x] 3.2 `Makefile`: add `package-build` target — stage each package's `:files` list into `build/<pkg>/` (copy, not symlink), byte-compile each staged module with `-L build/gptel-permit -L $(LOAD_PATH_GPTEL)` only; wire it as the default goal preceding `test`
- [x] 3.3 Add `package-lint` pass per staged package when the tool is available (non-fatal otherwise); record the expected lints (version ≥ pinned, Package-Requires shape, defcustom prefixes)
- [x] 3.4 Write the four MELPA recipe files (`etc/recipes/` or repo-local staging for the PR): `gptel-permit`, `gptel-permit-judge`, `gptel-permit-sandbox` (three files), `gptel-permit-analytics`; submit all four in one melpa/melpa PR — merge before tagging the split release

## 4. Test decoupling

- [x] 4.1 `tests/gptel-permit-rule-scopes-test.el`: replace the `gptel-permit-judge-safe-p` symbol fixture in the persisted-rule shape test with a test-local fboundp predicate; the file then loads with core only
- [x] 4.2 Add "requires: gptel-permit, gptel-permit-sandbox" (judge-action) and "requires: gptel-permit, gptel-permit-judge, gptel-permit-sandbox" (analytics) headers, making cross-module intent explicit in both integration suites
- [x] 4.3 Subset smoke runs by hand (not new ERT files): in fresh batch Emacsen, core-only / core+sandbox / core+judge / core+analytics each: load, byte-compile, run the suites whose files the subset contains; document the four-load-path one-liners in the Makefile comments

## 5. Docs

- [x] 5.1 README: installation section becomes a four-row matrix (package / what it gets you / requires / enablement snippet); analytics snippet becomes its own `use-package gptel-permit-analytics :after gptel-permit :config (gptel-permit-register-analytics-hooks)`; wording fix "installing is not loading" for judge and sandbox; judge Commentary notes the `(judge sandbox …)` cross-package fail-closed behavior
- [x] 5.2 AGENTS.org: "Basic Project Structure" gains the packaging section (four recipes, which files each owns, the staged byte-compile as enforcement, the one-PR recipe submission rule); "Integration Surface" gains the module-ABI list reference (the five helpers + four dynamic contracts)
- [x] 5.3 Full verification: `make package-build` + `make test` from a clean worktree; manual smoke in a fresh `emacs -Q` with a staged core-only install: validation, matching, wizard, `C-c C-b`; sandbox action unregistered → fail-closed confirm; log line reads "No handler for action sandbox"
