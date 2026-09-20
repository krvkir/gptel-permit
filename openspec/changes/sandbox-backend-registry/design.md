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
- A backend contract that is explicit, documented, and discoverable —
  enough structure that a third-party sandbox and the future `Eval`
  adapter plug in without touching the sandbox core.
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

1. **Backend contract: EIEIO classes + generic functions (CLOS).**
   Base class `gptel-permit-sandbox-backend` (stateless, no slots). The
   contract is two `cl-defgeneric`s:

   ```elisp
   (cl-defgeneric gptel-permit-sandbox-available-p (backend)
     "Return non-nil when BACKEND can run on this system.")
   (cl-defgeneric gptel-permit-sandbox-wrap (backend command root)
     "Return the sandboxed invocation string for COMMAND (project ROOT).")
   ```

   Stock backends subclass and specialize:

   ```elisp
   ;; gptel-permit-sandbox-bwrap.el
   (defclass gptel-permit-sandbox-backend-bwrap
     (gptel-permit-sandbox-backend) ())
   (cl-defmethod gptel-permit-sandbox-available-p
     ((_ gptel-permit-sandbox-backend-bwrap))
     (and (memq system-type '(gnu/linux)) (executable-find "bwrap")))
   (cl-defmethod gptel-permit-sandbox-wrap
     ((_ gptel-permit-sandbox-backend-bwrap) command root) …)
   ```

   A third-party backend is a subclass + two `cl-defmethod`s + one
   `add-to-list`:

   ```elisp
   (defclass my-nsjail-backend (gptel-permit-sandbox-backend) ())
   (cl-defmethod gptel-permit-sandbox-available-p ((_ my-nsjail-backend))
     (executable-find "nsjail"))
   (cl-defmethod gptel-permit-sandbox-wrap ((_ my-nsjail-backend) command root)
     (format "nsjail … %s" command))
   (add-to-list 'gptel-permit-sandbox-backends '(nsjail . my-nsjail-backend))
   ```

   *Why CLOS over the earlier plist shape* (`SYMBOL → (:available-p FN
   :wrap FN)`): the generic functions *are* the documented contract —
   signatures and docstrings live on the generics (`C-h f
   gptel-permit-sandbox-wrap` shows every implementation), methods are
   greppable, and subclassing gives shared-beavior hooks the plist cannot.
   The registry stays customize-friendly because it maps symbol → *class
   symbol* (plain printable data), not objects. Dispatch instantiates one
   stateless instance per class (cached in a small hash table keyed by
   class). Cost: authoring a backend is a subclass + two methods instead of
   one alist entry — acceptable ceremony for a security-relevant contract.
   *Alternative rejected:* `cl-defstruct` with function slots — typed but
   the contract is not named/discoverable, and method dispatch is manual.

2. **Stock backends in their own modules.**
   `gptel-permit-sandbox-bwrap.el` / `gptel-permit-sandbox-srt.el`: each
   defines its class, its two methods, and appends its entry to
   `gptel-permit-sandbox-backends` at load. `gptel-permit-sandbox.el`
   `require`s both (they are tiny, pure, and dependency-free); the defcustom
   default is built after the requires so the default registry is
   `((bwrap . gptel-permit-sandbox-backend-bwrap)
   (srt . gptel-permit-sandbox-backend-srt))`. The core retains the
   registry, resolver, adapter dispatch, latch, and hotkey — no
   backend-specific argv construction. AGENTS.org's project-structure list
   gains the two files.

3. **`auto` resolver is a function over the registry, memoized per session.**
   `gptel-permit--sandbox-resolve-backend`: `gnu/linux` → `bwrap`; otherwise
   first registered backend (registry order) whose available-p method
   returns non-nil, else nil. Memoize the result; re-resolve when
   `gptel-permit-sandbox-backends` changes (defcustom setter) — availability
   is re-verified at wrap time per call, so memoization only affects
   *choice*, not safety. Resolution is logged.
   *Why a platform check at all:* bwrap needs Linux user namespaces; srt is
   the cross-platform candidate. Non-Linux + no available backend → nil →
   fail-closed with a clear message, instead of silently claiming
   `builtin` and failing on every call.

4. **Tool adapters stay function-valued — deliberate asymmetry.**
   `gptel-permit-sandbox-adapters`: `"Bash" → (:wrap-args (args root) →
   new-args)`. Missing adapter → `(:confirm t)` + message (fail-closed, no
   guessing which key to wrap). *Why not CLOS here:* an adapter is a
   single-function contract and the alist keyed by tool name *is* the
   dispatch — a generic would add ceremony without polymorphism. Backends,
   by contrast, are a multi-method contract where CLOS pays for itself.
   Adapters rewrite arguments only — they SHALL NOT execute anything;
   execution stays gptel's (`:confirm nil` + rewritten args runs the tool
   as usual). The adapter contract must still support whole-call mechanics
   (the future Eval adapter: spawn a sandboxed Emacs subprocess holding the
   expression), hence args-in/args-out rather than string-in/string-out;
   an adapter whose own mechanics are unavailable may return a
   `(:confirm t)`-style verdict instead of args.

5. **Protected paths: single source, shared `./` semantics.**
   New core helper `gptel-permit--expand-protected-dir (dir &optional root)`:
   strings starting `./` resolve against `(gptel-permit--project-root)`
   (else `default-directory`); others go through `expand-file-name` (`~/`
   etc. unchanged). Used by `gptel-permit--inside-protected-dirs-p` and by
   the sandbox candidate builder. `gptel-permit-protected-dirs` default
   becomes `("~/.ssh/" "~/.gnupg/" "./.git")`. Sandbox drops its hardcoded
   entries (now redundant with the default).
   *Why `./` prefix:* matches the mental model of `.gitignore`-style
   project-relative paths and needs no new syntax. Nonexistent entries are
   still skipped at wrap time (bwrap can only bind existing paths).

6. **Sticky latch + explicit reset.** On reaching
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

7. **`C-c C-s` = `gptel-permit-accept-tool-calls-sandboxed`, all-or-nothing.**
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

8. **Analytics pending-key fix for rewritten args.** The decision advice
   pops pending confirmations by `(buffer tool args)`. Wrapping rewrites
   args between confirm and accept, orphaning the entry. The sandbox
   accept path (hotkey and, later, judge callbacks) SHALL pop the pending
   key for the *original* args before delegating to accept, so
   wait-time stats stay correct.

## Risks / Trade-offs

- [Custom `gptel-permit-protected-dirs` users silently lose the hardcoded
  .git/ssh/gnupg sandbox binds] → Accepted: no such users exist yet; README
  migration note says to add them to the option explicitly (they are in the
  new default).
- [Registry misuse — a broken `wrap` method could produce a non-sandboxing
  command string] → The backend contract is documented as
  *security-relevant*; fail-closed checks (missing backend, missing
  adapter, nil return from `wrap`) apply uniformly; `auto` only picks
  among backends that declare themselves available.
- [EIEIO ceremony discourages casual backends] → Accepted: sandboxing is
  security-relevant infrastructure, not a quick hook; the shipped
  bwrap/srt classes double as copy-paste templates in the README.
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
