## 1. Protected dirs single-source (`./` semantics)

- [ ] 1.1 Add `gptel-permit--expand-protected-dir (dir &optional root)` to gptel-permit.el: `./`-prefixed entries resolve against `gptel-permit--project-root` (fallback `default-directory`), others via `expand-file-name`
- [ ] 1.2 Use the helper in `gptel-permit--inside-protected-dirs-p`; add `./.git` to the `gptel-permit-protected-dirs` default and document `./` semantics in its docstring
- [ ] 1.3 ERT tests: `./` resolution with/without project, non-prefixed `~/` unchanged, predicate match on project-root-relative `.git` path

## 2. CLOS backend contract, registry, and bwrap rename

- [ ] 2.1 Define the base class `gptel-permit-sandbox-backend` and the two generics `gptel-permit-sandbox-available-p`, `gptel-permit-sandbox-wrap` in `gptel-permit-sandbox.el` (docstrings mark the contract security-relevant); define the registry defcustom `gptel-permit-sandbox-backends` (alist symbol → class symbol) with a setter that invalidates the memoized `auto` resolution
- [ ] 2.2 Extract `gptel-permit-sandbox-bwrap.el`: class `gptel-permit-sandbox-backend-bwrap`, `available-p` (gnu/linux + executable-find), `wrap` moved verbatim from `--sandbox-wrap-bwrap`; module appends its registry entry at load
- [ ] 2.3 Extract `gptel-permit-sandbox-srt.el`: class `gptel-permit-sandbox-backend-srt`, `available-p` (executable-find "srt"), `wrap` + settings-file generation moved verbatim; module appends its registry entry at load
- [ ] 2.4 Rename `'builtin` → `'bwrap` in `gptel-permit-sandbox-backend` (values `auto`/`bwrap`/`srt`; dynamic completion over registry symbols); update all dispatch sites (`--backend-available-p`, `--sandbox-action`) to registry lookups (instantiate + cache one stateless instance per class) with fail-closed on unknown symbol; drop all backend-specific argv construction from the core
- [ ] 2.5 Implement `gptel-permit--sandbox-resolve-backend` (Linux → bwrap; else first available registered; else nil), memoized, invalidated via the registry setter; re-verify `available-p` per wrap; log the resolved value; fail-closed `(:confirm t)` + message when resolution is nil
- [ ] 2.6 ERT tests: registry dispatch (stub subclass + methods), unknown-symbol fail-closed, resolver table (Linux bwrap / non-Linux first-available / none), memoization invalidation

## 3. Tool adapters

- [ ] 3.1 Define `gptel-permit-sandbox-adapters` defcustom (alist `"TOOL-NAME" → (:wrap-args (args root) → new-args)`) with the shipped "Bash" adapter; refactor `gptel-permit--sandbox-action` to go through the adapter and fail closed (`(:confirm t)` + message) for tools without one
- [ ] 3.2 ERT tests: Bash adapter wrapping, adapterless tool fails closed with message, adapter receives root, wrapped verdict preserves other args

## 4. Protected paths sourcing in the sandbox

- [ ] 4.1 Rewrite `gptel-permit--sandbox-protected-paths` to resolve via `gptel-permit--expand-protected-dir` over `gptel-permit-protected-dirs` + rc-files const; drop hardcoded `ROOT/.git`/`~/.ssh`/`~/.gnupg`; update the sandbox spec wording and the two existing dedup/protected-paths tests
- [ ] 4.2 ERT tests: candidates fully driven by the option (+rc files), `./.git` default binds read-only, nonexistent entries skipped

## 5. Failure latch

- [ ] 5.1 Add buffer-local `gptel-permit--sandbox-latched`; on limit trip set latch (no counter auto-reset) and message naming `gptel-permit-sandbox-reset`; every sandbox verdict while latched → `(:confirm t)` + message; clear latch+counter on sandboxed success (post-tool hook)
- [ ] 5.2 Add interactive `gptel-permit-sandbox-reset` (resets latch + counter in current buffer, messages confirmation); update the `--remember` docstring (result-attribution registry purpose, bounded 100)
- [ ] 5.3 ERT tests: trip sets latch and keeps it sticky, reset command clears, success clears, verdicts while latched are `(:confirm t)`

## 6. Interactive sandboxed acceptance (`C-c C-s`)

- [ ] 6.1 Implement `gptel-permit-accept-tool-calls-sandboxed`: read pending triples at point via `get-char-property-and-overlay`; rewrite each call's args via adapters; all-or-nothing — any adapterless tool or unavailable backend → message naming it, no accept; otherwise `gptel--accept-tool-calls` with modified triples; pop the analytics pending entry with pre-rewrite args before delegating
- [ ] 6.2 Bind `C-c C-s` in `gptel-tool-call-actions-map` on sandbox module load (unbind on unload path, mirroring `gptel-permit-mode` handling)
- [ ] 6.3 ERT tests: all-wrapped accept calls accept with rewritten args, mixed pack refuses entirely (stub overlay + triples), no-pending-calls message

## 7. Docs and verification

- [ ] 7.1 README: CLOS backend authoring guide (subclass + two methods + add-to-list, with the security caveat and the shipped classes as templates), `./` protected-dirs semantics + migration note (`'builtin` → `'bwrap`; re-add `./.git` if the option was customized), latch + reset semantics, `C-c C-s` key
- [ ] 7.2 Update AGENTS.org project-structure list with the two new backend files
- [ ] 7.3 Byte-compile all files, run full ERT suite (`make test`); update tests pinning `'builtin`/old candidate sets
- [ ] 7.4 Manual pass: bwrap sandbox still contains (write to project OK, `.git` and `~/.ssh` blocked, network off); `C-c C-s` on a live pending call; latch trip via forced boundary failure then reset
