## 1. Protected dirs single-source (`./` semantics)

- [x] 1.1 Add `gptel-permit--expand-protected-dir (dir &optional root)` to gptel-permit.el: `./`-prefixed entries resolve against `gptel-permit--project-root` (fallback `default-directory`), others via `expand-file-name`
- [x] 1.2 Use the helper in `gptel-permit--inside-protected-dirs-p`; add `./.git` to the `gptel-permit-protected-dirs` default and document `./` semantics in its docstring
- [x] 1.3 ERT tests: `./` resolution with/without project, non-prefixed `~/` unchanged, predicate match on project-root-relative `.git` path

## 2. CLOS backend contract, registry, and bwrap rename

- [x] 2.1 Define the base class `gptel-permit-sandbox-backend-base` (NOT `gptel-permit-sandbox-backend`: EIEIO's `defclass` binds the class name as a variable, which silently clobbers the option of that name — found in implementation, pinned by `gptel-permit-sandbox-default-option-is-auto`) and the two generics `gptel-permit-sandbox-available-p`, `gptel-permit-sandbox-wrap` in `gptel-permit-sandbox.el` (docstrings mark the contract security-relevant); define the registry defcustom `gptel-permit-sandbox-backends` (alist symbol → class symbol; entries are inert printable data); define the feature table `gptel-permit--sandbox-backend-features` mapping shipped backend symbols → feature names
- [x] 2.2 Extract `gptel-permit-sandbox-bwrap.el`: class `gptel-permit-sandbox-backend-bwrap`, `available-p` (gnu/linux + executable-find), `wrap` moved verbatim from `--sandbox-wrap-bwrap`; module appends its registry entry at load
- [x] 2.3 Extract `gptel-permit-sandbox-srt.el`: class `gptel-permit-sandbox-backend-srt`, `available-p` (executable-find "srt"), `wrap` + settings-file generation moved verbatim; module appends its registry entry at load
- [x] 2.4 Rename `'builtin` → `'bwrap` in `gptel-permit-sandbox-backend` (values `auto` + any registry symbol; plain symbol type, no validation — unknown symbols self-heal via lazy require); update all dispatch sites (`--backend-available-p`, `--sandbox-action`) to lazy-require-then-registry-lookup (instantiate + cache one stateless instance per class) with fail-closed on unknown symbol; drop all backend-specific argv construction from the core
- [x] 2.5 Implement `gptel-permit--sandbox-resolve-backend` from the static platform table `gptel-permit--sandbox-auto-prefs` (gnu/linux → bwrap; darwin/windows-nt → srt; else nil), no memoization, re-resolved per call; lazy-require the table-selected backend's module; re-verify `available-p` per call; log the resolved value; fail-closed `(:confirm t)` + message when resolution is nil (no cross-fallback)
- [x] 2.6 ERT tests: registry dispatch (stub subclass + methods), unknown-symbol fail-closed, resolver platform table (Linux bwrap / darwin srt / unknown platform nil / missing binary nil, no cross-fallback), per-call re-resolution picks up a newly "installed" binary, backend modules not loaded until first dispatch, and the option's default surviving class definition (the EIEIO name-collision regression)

## 3. Tool adapters

- [x] 3.1 Define `gptel-permit-sandbox-adapters` defcustom (alist `"TOOL-NAME" → (:wrap-args (args root) → new-args)`) with the shipped "Bash" adapter; refactor `gptel-permit--sandbox-action` to go through the adapter and fail closed (`(:confirm t)` + message) for tools without one
- [x] 3.2 ERT tests: Bash adapter wrapping, adapterless tool fails closed with message, adapter receives root, wrapped verdict preserves other args

## 4. Protected paths sourcing in the sandbox

- [x] 4.1 Rewrite `gptel-permit--sandbox-protected-paths` to resolve via `gptel-permit--expand-protected-dir` over `gptel-permit-protected-dirs` + rc-files const; drop hardcoded `ROOT/.git`/`~/.ssh`/`~/.gnupg`; update the sandbox spec wording and the two existing dedup/protected-paths tests
- [x] 4.2 ERT tests: candidates fully driven by the option (+rc files), `./.git` default binds read-only, nonexistent entries skipped
- [x] 4.3 Symlinked protected paths: bind the target, not the link. bubblewrap refuses a symlink destination ("Can't mount on symlink destination") and aborts the whole invocation — a stow/chezmoi-managed `~/.zshrc` broke every sandboxed command until this. Implemented as `gptel-permit-sandbox--bind-dests` in the bwrap backend (the constraint is bubblewrap-specific), ERT test + spec/README wording. Found by the task 7.4 manual pass.

## 5. Failure latch

- [x] 5.1 Add buffer-local `gptel-permit--sandbox-latched`; on limit trip set latch (no counter auto-reset) and message naming `gptel-permit-sandbox-reset`; every sandbox verdict while latched → `(:confirm t)` + message; clear latch+counter on sandboxed success (post-tool hook)
- [x] 5.2 Add interactive `gptel-permit-sandbox-reset` (resets latch + counter in current buffer, messages confirmation); update the `--remember` docstring (result-attribution registry purpose, bounded 100)
- [x] 5.3 ERT tests: trip sets latch and keeps it sticky, reset command clears, success clears, verdicts while latched are `(:confirm t)`

## 6. Interactive sandboxed acceptance (`C-c C-s`)

- [x] 6.1 Implement `gptel-permit-accept-tool-calls-sandboxed`: read pending triples at point via `get-char-property-and-overlay`; rewrite each call's args via adapters; all-or-nothing — any adapterless tool or unavailable backend → message naming it, no accept; otherwise `gptel--accept-tool-calls` with modified triples; pop the analytics pending entry with pre-rewrite args before delegating
- [x] 6.2 Bind `C-c C-s` in `gptel-tool-call-actions-map` on sandbox module load (unbind on unload path, mirroring `gptel-permit-mode` handling)
- [x] 6.3 ERT tests: all-wrapped accept calls accept with rewritten args, mixed pack refuses entirely (stub overlay + triples), no-pending-calls message

## 7. Docs and verification

- [x] 7.1 README: backend selection (`auto` platform table + registry), CLOS backend authoring guide (subclass + two methods + add-to-list, with the security caveat, the `-base` naming constraint, and the shipped classes as templates), tool-adapter guide, `./` protected-dirs semantics + migration note (`'builtin` → `'bwrap`; re-add `./.git` if the option was customized), latch + reset semantics, `C-c C-s` key, known limitations (symlinked protected paths, backend-specific options)
- [x] 7.2 Update AGENTS.org: project-structure list with the two new backend files, the sandbox bullet (registry, adapters, latch, hotkey), the `C-c C-s`/`gptel--accept-tool-calls` integration entries, and the sandbox extension-point bullet with the EIEIO naming rule
- [x] 7.3 Byte-compile all files, run full ERT suite (`make test`) — 229/229 — update tests pinning `'builtin`/old candidate sets
- [x] 7.4 Manual pass, run as a scripted batch smoke test against the real bwrap (`bwrap` present on this machine): write inside the project root OK; write into `.git` refused ("Read-only file system"); write through the symlinked `~/.zshrc` refused; read `~/.ssh` OK, write refused; `/proc/net/dev` shows only `lo` (network off); write outside the root refused and the target file never created. The interactive paths (`C-c C-s` on a live pending call, latch trip then reset) are covered by ERT rather than by hand.
- [x] 7.5 Update the openspec delta docs to the revised decisions if any wording drifted (platform-table `auto`, lazy backend modules, no customization validation, `-base` class name, symlinked protected paths)
