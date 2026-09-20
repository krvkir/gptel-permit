# sandbox Delta

## MODIFIED Requirements

### Requirement: Sandbox action
The rule engine SHALL support `:action sandbox`. When a sandbox rule matches
a tool call, the hook SHALL dispatch to the tool's sandbox adapter and return
`(:confirm nil :args REWRITTEN)` where REWRITTEN is the adapter's rewritten
argument plist (for Bash, `:command` prefixed by the configured sandbox
backend). Rules, the judge, and validation SHALL always see the original,
unwrapped arguments. A tool without a registered adapter SHALL fail closed
with `(:confirm t)` and a message naming the tool; this replaces any
key-specific sniffing in the sandbox core.

#### Scenario: Execute command is wrapped and auto-accepted
- GIVEN a rule `(:tool-group execute :action sandbox)` and backend bwrap with bwrap on exec-path
- WHEN a Bash call with `:command "make test"` is evaluated
- THEN the hook returns `(:confirm nil :args …)` whose `:command` begins with the bwrap invocation and embeds `make test` (shell-quoted)
- AND the rule match was computed against "make test", not the wrapped string.

#### Scenario: Ask rule above sandbox escapes the sandbox
- GIVEN a session rule `(:tool "Bash" :conditions ((:command . "^ssh ")) :action ask)` listed before the sandbox rule
- WHEN a Bash call `:command "ssh prod uptime"` is evaluated
- THEN the ask rule fires and returns `(:confirm t)` with the original
  command (no wrapping), so user approval runs it unsandboxed.

#### Scenario: Tool without adapter fails closed
- GIVEN a rule `(:tool-group execute :action sandbox)` matching an Eval call
  and no adapter registered for "Eval"
- WHEN the call is evaluated
- THEN the hook returns `(:confirm t)` and nothing is auto-run
- AND a message names the tool as lacking a sandbox adapter.

### Requirement: Mandatory protected paths
The wrapper SHALL read-only bind (when the path exists at wrap time) every
entry of `gptel-permit-protected-dirs` — including its `./.git` default —
resolved with the shared project-root-relative rules of
`gptel-permit--expand-protected-dir`, plus the shell rc files
(`~/.bashrc`, `~/.bash_profile`, `~/.profile`, `~/.zshrc`). The sandbox SHALL
NOT add its own hardcoded entries: `gptel-permit-protected-dirs` is the
single source of truth. Nonexistent paths SHALL be skipped (bwrap
limitation, documented in README).

#### Scenario: .git protected by default via protected-dirs
- GIVEN default `gptel-permit-protected-dirs` ("~/.ssh/" "~/.gnupg/" "./.git")
  and project root "/home/user/proj/" with an existing ".git" directory
- WHEN the wrapper is built
- THEN `--ro-bind /home/user/proj/.git /home/user/proj/.git` is present after
  the project `--bind`, so writes to hooks/config fail inside the sandbox.

#### Scenario: Customized protected-dirs fully controls protection
- GIVEN `gptel-permit-protected-dirs` is ("~/.ssh/" "./.git")
- WHEN the wrapper is built
- THEN exactly the resolved entries of that option plus the rc files are
  read-only bound — the sandbox adds nothing beyond its rc-file constant.

### Requirement: Fail-closed backend detection
The sandbox action SHALL fail closed: when the resolved backend declares
itself unavailable (binary not on exec-path, wrong platform), it SHALL
return `(:confirm t)` and log the reason, naming the backend. When `auto`
resolves to nil (no backend available on the platform), it SHALL return
`(:confirm t)` and message that no sandbox backend is available.

#### Scenario: bwrap missing
- GIVEN the resolved backend is bwrap and bwrap is not on exec-path
- WHEN a sandbox rule matches
- THEN the hook returns `(:confirm t)`.

#### Scenario: auto resolves to nothing
- GIVEN `gptel-permit-sandbox-backend` is `auto` on a platform with no
  available registered backend
- WHEN a sandbox rule matches
- THEN the hook returns `(:confirm t)` with a message that no sandbox backend
  is available.

## REMOVED Requirements

### Requirement: Builtin bwrap wrapper
**Reason**: The `builtin` backend was renamed to `bwrap` (honest naming); the
wrapper requirement is superseded by the bwrap backend class's wrap method
with identical argv semantics, dispatched through the backend registry.
**Migration**: The wrapper shape is unchanged; configure
`gptel-permit-sandbox-backend` as `bwrap` instead of `builtin`.

### Requirement: srt backend (opt-in)
**Reason**: Replaced by the registry-shaped srt backend class; `auto` may now
resolve to srt on non-Linux platforms, so "(opt-in)" framing is stale.
**Migration**: `srt` remains a valid `gptel-permit-sandbox-backend` value;
settings-file mapping semantics are unchanged.

## ADDED Requirements

### Requirement: Backend registry
The sandbox SHALL dispatch all wrapping through
`gptel-permit-sandbox-backends`: an alist mapping a backend symbol to the
backend's class, where every backend class is a subclass of
`gptel-permit-sandbox-backend` implementing two generic operations —
`gptel-permit-sandbox-available-p (backend)` (can this backend run here?)
and `gptel-permit-sandbox-wrap (backend command root)` (return the sandboxed
invocation string). The shipped registry SHALL contain `bwrap` and `srt`;
users MAY add their own backend symbol → class pairs and MAY replace
shipped entries. An unknown backend symbol SHALL fail closed with
`(:confirm t)` and a log line naming the symbol. The backend contract SHALL
be documented as security-relevant: a wrap method's output runs without
further confirmation, so a broken wrapper effectively disables sandboxing.

#### Scenario: Custom backend participates
- GIVEN a user defines a subclass of `gptel-permit-sandbox-backend`
  implementing both generics, registers it as `my-sandbox`, and sets
  `gptel-permit-sandbox-backend` to `my-sandbox`
- WHEN a sandbox rule matches a Bash call
- THEN the command is wrapped via that backend's wrap method and auto-run
  when it returns a string.

#### Scenario: Unknown backend fails closed
- GIVEN `gptel-permit-sandbox-backend` is `docker-sandbox` (not in the registry)
- WHEN a sandbox rule matches
- THEN the hook returns `(:confirm t)` and the log names the unknown backend.

### Requirement: Stock backend modules
The shipped bwrap and srt backends SHALL be provided as separate library
files — `gptel-permit-sandbox-bwrap.el` and `gptel-permit-sandbox-srt.el` —
each defining its backend class, its two generic methods, and contributing
its registry entry. The sandbox core SHALL load both modules and SHALL NOT
contain backend-specific wrapper construction itself.

#### Scenario: Core contains no backend argv construction
- GIVEN the sandbox core and both backend modules are loaded
- WHEN bwrap and srt wrapper construction is searched for in
  `gptel-permit-sandbox.el`
- THEN none is found — all wrapper strings come from the backend classes.

### Requirement: auto resolution
When `gptel-permit-sandbox-backend` is `auto`, the sandbox SHALL resolve the
backend once per session: on GNU/Linux resolve to `bwrap`; on other platforms
resolve to the first registered backend (registry order) whose available-p
method returns non-nil; resolve to nil when none is available. Resolution
SHALL consider user-registered backends, so a third-party backend becomes
reachable via `auto` without code changes. The resolved value SHALL be
re-resolved when the registry changes, and availability SHALL be re-verified
at wrap time per call. The resolved value SHALL be reported in the log.

#### Scenario: Linux resolves to bwrap
- GIVEN `system-type` is `gnu/linux` and bwrap is on exec-path
- WHEN the backend is resolved for the first time
- THEN `auto` resolves to `bwrap`.

#### Scenario: Non-Linux picks first available registered backend
- GIVEN `system-type` is `darwin`, `srt` is not installed, and a
  user-registered backend `mac-sandbox` whose available-p method returns t
- WHEN the backend is resolved
- THEN `auto` resolves to `mac-sandbox`.

#### Scenario: Nothing available resolves to nil
- GIVEN `system-type` is `windows-nt` and no registered backend is available
- WHEN the backend is resolved
- THEN `auto` resolves to nil and every sandbox action fails closed.

### Requirement: bwrap backend wrapper
The bwrap backend's wrap method SHALL construct:
`bwrap --die-with-parent --new-session --clearenv [--setenv V v]… --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp [--unshare-net] [--bind DIR DIR]… [--ro-bind P P]… -- bash -c QUOTED`
where writable binds come from `gptel-permit-sandbox-writable-dirs` (default:
the project root), `--unshare-net` is present unless
`gptel-permit-sandbox-network` is non-nil, env vars come from
`gptel-permit-sandbox-env-keep`, and QUOTED is the original command through
POSIX single-quoting (quote-once semantics of `shell-quote-argument`).
The root MUST be bound read-only (`--ro-bind / /` plus fresh `--dev`/`--proc`
mounts).

#### Scenario: Wrapper shape
- GIVEN default settings, project root "/home/user/proj/", command "make test"
- WHEN the wrapper is built
- THEN it contains `--ro-bind / /`, `--dev /dev`, `--proc /proc`,
  `--tmpfs /tmp`, `--unshare-net`,
  `--bind /home/user/proj/ /home/user/proj/`, and ends with
  `-- bash -c 'make test'`.

#### Scenario: Environment scrubbing
- GIVEN `gptel-permit-sandbox-env-keep` is ("PATH" "HOME")
- WHEN the wrapper is built
- THEN it contains `--clearenv` and `--setenv` entries only for those
  variables that are set in the Emacs environment.

### Requirement: srt backend
The srt backend's wrap method SHALL write a settings file mapping
`gptel-permit-sandbox-writable-dirs` to `filesystem.allowWrite`, protected
paths to `filesystem.denyRead`/mandatory denies, and
`gptel-permit-sandbox-allowed-domains` to `network.allowedDomains`, via
`json-encode`, and wrap the command as `srt --settings FILE COMMAND`. The
`auto` resolver MAY resolve to `srt` on non-Linux platforms when its binary
is available.

#### Scenario: Settings reflect defcustoms
- GIVEN writable-dirs ("~/proj/") and allowed-domains ("github.com")
- WHEN the srt settings file is generated
- THEN its JSON contains filesystem.allowWrite ["~/proj/"] and
  network.allowedDomains ["github.com"].

### Requirement: Tool adapter registry
The sandbox SHALL rewrite tool-call arguments through
`gptel-permit-sandbox-adapters`: an alist mapping a tool name (string) to
a plist `(:wrap-args (args root) → new-args)`. The shipped registry SHALL
contain a "Bash" adapter wrapping `:command` via the resolved backend.
Adapters rewrite arguments only — they SHALL NOT execute anything. The
adapter contract SHALL support whole-call mechanics (e.g. a future "Eval"
adapter spawning a sandboxed Emacs for the expression), which is why the
contract is args-in/args-out rather than string-in/string-out. A tool call
matching a sandbox rule with no registered adapter SHALL fail closed with
`(:confirm t)` and a message naming the tool.

#### Scenario: Bash adapter wraps command
- GIVEN the shipped "Bash" adapter and backend bwrap
- WHEN a Bash call with `:command "cargo test"` is sandboxed
- THEN the returned args carry a `:command` equal to the bwrap-wrapped string.

#### Scenario: Eval adapter is a registry entry, not core code
- GIVEN a future user-added "Eval" adapter entry
- WHEN an Eval call matches a sandbox rule
- THEN the sandbox core rewrites the call purely via the registry — no
  sandbox-core change is needed to support the new tool.

### Requirement: Sandbox failure latch
The buffer SHALL latch when `gptel-permit-sandbox-retry-limit` consecutive
sandboxed-command boundary failures are reached: every subsequent
sandbox verdict SHALL be `(:confirm t)` with a message naming
`gptel-permit-sandbox-reset`, until either a sandboxed command succeeds
(clearing latch and counter via the post-tool hook) or the user runs
`gptel-permit-sandbox-reset` (interactive, resets the counter and latch in
the current buffer). The latch SHALL NOT silently auto-clear when tripped.

#### Scenario: Latch is sticky
- GIVEN three consecutive sandboxed boundary failures (limit 3)
- WHEN two further sandbox-eligible calls arrive
- THEN both receive `(:confirm t)` with the reset-command message
- AND the latch remains set.

#### Scenario: Success clears the latch
- GIVEN the buffer is latched
- WHEN a user-confirmed sandboxed command completes without a boundary error
- THEN the latch and the failure counter are cleared
- AND the next sandbox-eligible call auto-runs again.

#### Scenario: Explicit reset
- GIVEN the buffer is latched
- WHEN the user invokes `gptel-permit-sandbox-reset`
- THEN the latch and counter are cleared in that buffer and a message
  confirms it.

### Requirement: Interactive sandboxed acceptance
The sandbox module SHALL bind `C-c C-s` in `gptel-tool-call-actions-map` to
`gptel-permit-accept-tool-calls-sandboxed`, which takes the pending tool
calls from the overlay at point and rewrites each call's args through its
registered adapter. Acceptance SHALL be all-or-nothing: if every pending
call has an adapter (and the backend is available), the calls are accepted
via `gptel--accept-tool-calls` with rewritten args; if any call lacks an
adapter or the backend is unavailable, NOTHING is accepted and a message
names the offending tool (the user can still accept unwrapped with
`C-c C-c`). It SHALL message and not accept when there are no pending tool
calls at point.

#### Scenario: Hotkey wraps and accepts
- GIVEN a pending Bash call `:command "make test"` at point and the bwrap
  backend available
- WHEN `C-c C-s` is pressed
- THEN the call is accepted with `:command` rewritten to the bwrap-wrapped
  string (the original pending triple is not executed unwrapped).

#### Scenario: Mixed pack refuses entirely
- GIVEN pending calls for "Bash" and "Eval" (no Eval adapter) at point
- WHEN `C-c C-s` is pressed
- THEN nothing is accepted, a message names "Eval" as lacking a sandbox
  adapter, and the prompt remains for the user to accept with `C-c C-c` or
  reject.
