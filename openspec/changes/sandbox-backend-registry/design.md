## Context

`gptel-permit-sandbox.el` ships two hardwired backends behind
`gptel-permit-sandbox-backend` (`auto` ≡ `builtin` ≡ bwrap; `srt` opt-in).
The `sandbox` action (`gptel-permit--sandbox-action`) rewrites `:command`
in place, fails closed when the backend binary is missing, and tracks
consecutive boundary failures in `gptel-permit--sandbox-fail-streak`
(auto-resetting the streak when the retry limit trips — the confusing
"how do I reset it" semantics). Protected paths
(`gptel-permit--sandbox-protected-paths`) hardcode `ROOT/.git`, `~/.ssh`,
`~/.gnupg` plus the `gptel-permit-protected-dirs` entries — duplicating the
core option's default. Only Bash-shaped calls (`:command`) can be wrapped.

gptel facts this design leans on: pending confirmations are triples
`(tool-spec args process-tool-result)` on the overlay's `gptel-tool`
property; `gptel--accept-tool-calls (&optional tool-calls ov)` accepts
possibly-edited tool call lists; `gptel-tool-call-actions-map` binds
`C-c C-c`/`C-c C-k`/`C-c C-r`/`C-c C-i`/`mouse-1`, leaving `C-c C-s` free.

## Goals / Non-Goals

**Goals:**
- Honest backend naming and platform-aware `auto` that fails closed visibly
  when no backend is available.
- Two extension points — backends and tool adapters — sufficient for a
  third-party sandbox and for the future `Eval` adapter without core changes.
- One source of truth for protected paths, with project-root-relative `./`
  entries working identically for rules and sandbox.
- Understandable failure gating: sticky latch + explicit reset command.
- `C-c C-s` to sandbox-and-accept pending calls interactively.

**Non-Goals:**
- Writing the `Eval` adapter (its design is sketched here only as the
  registry's motivating case; implementation is a separate change).
- Network allowlisting for the bwrap backend (still binary on/off; srt
  keeps `gptel-permit-sandbox-allowed-domains`).
- Any change to the `allow`/`deny`/`ask` action paths.

## Decisions

1. **Backend registry shape: `SYMBOL → (:available-p FN :wrap FN)`.**
   `:wrap (command root) → string` keeps the existing
   `--sandbox-wrap-bwrap`/`--sandbox-wrap-srt` signatures untouched — the
   shipped entries are thin structs around them. Dispatch goes through
   `alist-get` on the resolved symbol; unknown symbol → fail-closed
   `(:confirm t)` + log. *Alternative rejected:* defclass-based backend
   objects — heavier than needed for a 2-function contract, worse to
   document in customize.

2. **`auto` resolver is a function over the registry, memoized per session.**
   `gptel-permit--sandbox-resolve-backend`: `gnu/linux` → `bwrap`; otherwise
   first registered backend whose `:available-p` holds (registration order),
   else nil. Memoize the result; re-resolve when
   `gptel-permit-sandbox-backends` is changed (`set` in the defcustom
   setter) or when the resolved backend's `:available-p` later returns nil
   (checked at wrap time anyway — availability is re-verified per call, so
   memoization only affects *choice*, not safety).
   *Why a platform check at all:* bwrap is Linux-only (bubblewrap needs user
   namespaces); srt is the cross-platform candidate. Non-Linux + no srt →
   nil → fail-closed with a clear message, instead of silently claiming
   `builtin` and failing on every call.

3. **Tool adapters are per-tool-name args rewriters.**
   `gptel-permit-sandbox-adapters`: `"Bash" → (:wrap-args (args root) → args)`
   default entry. The adapter returns a *new args plist*; the sandbox action
   uses `(plist-put (copy-sequence args) :command wrapped)` for Bash exactly
   as today. Missing adapter → `(:confirm t)` + message (fail-closed, no
   guessing which key to wrap). *Why adapters keyed by tool name, not by
   arg-key:* the Eval case — spawn a sandboxed Emacs subprocess holding the
   expression — cannot be expressed as "wrap some string arg"; it needs a
   whole different execution strategy, which lives behind the same
   `:wrap-args` contract (the adapter may also return a verdict with
   `:confirm t` when its own mechanics are unavailable).
   *Note:* adapters wrap; they do not execute. Execution stays gptel's
   (`:confirm nil` + rewritten args runs the tool as usual). The Eval
   adapter's subprocess design: `bwrap … emacs --batch --eval EXPR` (or a
   persistent sandboxed Emacs daemon for speed) — out of scope here, but the
   registry contract must not preclude it, hence args-in/args-out rather
   than string-in/string-out.

4. **Protected paths: single source, shared `./` semantics.**
   New core helper `gptel-permit--expand-protected-dir (dir &optional root)`:
   strings starting `./` resolve against `(gptel-permit--project-root)`
   (else `default-directory`); others go through `expand-file-name` (`~/`
   etc. unchanged). Used by `gptel-permit--inside-protected-dirs-p` and by
   the sandbox candidate builder. `gptel-permit-protected-dirs` default
   becomes `("~/.ssh/" "~/.gnupg/" "./.git")`. Sandbox drops its hardcoded
   `ROOT/.git` / `~/.ssh` / `~/.gnupg` (now redundant with the default).
   *Why `./` prefix:* matches the mental model of `.gitignore`-style
   project-relative paths and needs no new syntax. Nonexistent entries are
   still skipped at wrap time (bwrap can only bind existing paths).

5. **Sticky latch + explicit reset.** On reaching
   `gptel-permit-sandbox-retry-limit` consecutive boundary failures, set
   buffer-local `gptel-permit--sandbox-latched` (new var;
   `gptel-permit--sandbox-fail-streak` remains the counter). While latched,
   every sandbox verdict is `(:confirm t)` with a message naming the reset
   command. Cleared by: any sandboxed command succeeding (post-tool hook
   resets counter + latch, as today) or `gptel-permit-sandbox-reset`
   (interactive, current buffer).
   *Why:* the old auto-reset-on-trip meant "reset" was invisible and the
   next call silently auto-ran — triage happened once and then the streak
   machinery went back to sleep. The latch keeps triage sticky until
   evidence (a success) or an explicit human decision clears it. The
   `--remember` registry stays as-is (it exists so the post-tool hook can
   attribute results to sandboxed commands — docstring gets this).

6. **`C-c C-s` = `gptel-permit-accept-tool-calls-sandboxed`, all-or-nothing.**
   Reads the pending triples from the overlay at point
   (`get-char-property-and-overlay` like `gptel--accept-tool-calls`), runs
   each call's args through the tool's adapter, and delegates to
   `gptel--accept-tool-calls` with the modified list — but only when *every*
   call has an adapter and the backend is available. Any adapterless call or
   missing backend → refuse entirely with a message naming the tool (the
   user can still accept unwrapped via `C-c C-c`; accepting one call
   unwrapped under a "sandbox accept" key would violate least-surprise).
   Bind on sandbox module load in `gptel-tool-call-actions-map`; unbind on
   unload.
   *Why not `C-u C-c C-c`:* gptel's accept command doesn't read a prefix
   arg, so `C-u` would be a silent no-op there and rebinding it changes
   upstream behavior; `C-c C-s` is free, memorable ("s"andbox), and
   `describe-keymap`-discoverable.

7. **Analytics pending-key fix for rewritten args.** The decision advice
   pops pending confirmations by `(buffer tool args)`. Wrapping rewrites
   args between confirm and accept, orphaning the entry. The sandbox
   accept path (hotkey and, later, judge callbacks) SHALL emit the decision
   event itself (or pop the pending entry with pre-rewrite args) so
   wait-time stats stay correct. Concretely: the hotkey pops the pending
   key for the *original* args before delegating to accept.

## Risks / Trade-offs

- [Custom `gptel-permit-protected-dirs` users silently lose the hardcoded
  .git/ssh/gnupg sandbox binds] → Accepted: no such users exist yet; README
  migration note says to add them to the option explicitly (they are in the
  new default).
- [Registry misuse — a broken `:wrap` could produce a non-sandboxing
  command string] → The adapter/backend contract is documented as
  *security-relevant*; fail-closed checks (missing backend, missing
  adapter, nil return from `:wrap`) apply uniformly; `auto` only picks
  among backends that declare themselves available.
- [Memoized `auto` picks a backend that later disappears] → Availability
  is re-checked at every wrap; a missing binary fails closed per call.
- [Latch makes an unattended session stall on sandboxed calls] → That is
  the intended triage semantics; the message names `gptel-permit-sandbox-reset`
  and the README documents auto-clearing on first success.

## Migration Plan

- `'builtin` → `'bwrap` rename: customize-set old value fails validation;
  one-line migration in README (no code shim — there are no external users).
- Default `gptel-permit-protected-dirs` changes: README note (users
  overriding the default should re-add `./.git`).
- Everything else additive. Rollback: revert commit; stale latch var is
  buffer-local and harmless.

## Open Questions

- Should `gptel-permit-sandbox-backend` accept arbitrary registry symbols
  directly (validate against `gptel-permit-sandbox-backends` at customize
  time)? Leaning yes — the defcustom type becomes a symbol choice with a
  dynamic completion list, defaulting `auto`.
- Persistent sandboxed Emacs for the future Eval adapter (daemon vs
  per-call `--batch`): deferred to the Eval adapter change.
