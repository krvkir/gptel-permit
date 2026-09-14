# Sandbox Specification

## Purpose
Provide the OS-level `sandbox` rule action for execute-group tool calls: the
tool call's command is rewritten through a sandbox backend and auto-executed
inside a filesystem/network boundary, failing closed whenever the boundary
cannot be established.

## Requirements

### Requirement: Sandbox action
The rule engine SHALL support `:action sandbox`. When a sandbox rule matches
an execute-group tool call, the hook SHALL return
`(:confirm nil :args (:command WRAPPED))` where WRAPPED is the original
command prefixed by the configured sandbox backend. Rules, the judge, and
validation SHALL always see the original, unwrapped command.

#### Scenario: Execute command is wrapped and auto-accepted
- GIVEN a rule `(:tool-group execute :action sandbox)` and backend builtin with bwrap on exec-path
- WHEN a Bash call with `:command "make test"` is evaluated
- THEN the hook returns `(:confirm nil :args …)` whose `:command` begins with the bwrap invocation and embeds `make test` (shell-quoted)
- AND the rule match was computed against "make test", not the wrapped string.

#### Scenario: Ask rule above sandbox escapes the sandbox
- GIVEN a session rule `(:tool "Bash" :conditions ((:command . "^ssh ")) :action ask)` listed before the sandbox rule
- WHEN a Bash call `:command "ssh prod uptime"` is evaluated
- THEN the ask rule fires and returns `(:confirm t)` with the original
  command (no wrapping), so user approval runs it unsandboxed.

#### Scenario: Tool without :command fails closed
- GIVEN a rule `(:tool-group execute :action sandbox)` matching an Eval call
- WHEN the call is evaluated (Eval carries `:expression`, not `:command`)
- THEN the hook returns `(:confirm t)` and nothing is auto-run.

### Requirement: Builtin bwrap wrapper
The builtin backend SHALL construct:
`bwrap --die-with-parent --new-session --clearenv [--setenv V v]… --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp [--unshare-net] [--bind DIR DIR]… [--ro-bind P P]… -- bash -c QUOTED`
where writable binds come from `gptel-permit-sandbox-writable-dirs` (default:
the project root), `--unshare-net` is present unless
`gptel-permit-sandbox-network` is non-nil, env vars come from
`gptel-permit-sandbox-env-keep`, and QUOTED is the original command through
POSIX single-quoting (quote-once semantics of `shell-quote-argument`).

Note: the root MUST be bound read-only (`--ro-bind / /` plus fresh
`--dev`/`--proc` mounts). The originally drafted `--dev-bind / /` shape was
replaced during implementation: `--dev-bind` produces a read-WRITE root
binding, which would have defeated the sandbox entirely (verified
empirically against bubblewrap 0.12: `/etc` remained writable under
`--dev-bind / /`, and stays read-only under `--ro-bind / /`).

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

### Requirement: Mandatory protected paths
The wrapper SHALL read-only bind (when the path exists at wrap time):
`<project-root>/.git`, `~/.ssh`, `~/.gnupg`, existing shell rc files
(`~/.bashrc`, `~/.bash_profile`, `~/.profile`, `~/.zshrc`), and every entry
of `gptel-permit-protected-dirs`. Nonexistent paths SHALL be skipped (bwrap
limitation, documented in README).

#### Scenario: .git protected even though project is writable
- GIVEN project root "/home/user/proj/" with an existing ".git" directory
- WHEN the wrapper is built
- THEN it contains `--ro-bind /home/user/proj/.git /home/user/proj/.git`
  after the project `--bind`, so writes to hooks/config fail inside the
  sandbox.

### Requirement: Fail-closed backend detection
The sandbox action SHALL fail closed: when the configured backend's binary
is not on `exec-path`, it SHALL return `(:confirm t)` and log the reason.

#### Scenario: bwrap missing
- GIVEN `gptel-permit-sandbox-command` is "bwrap" and `(executable-find "bwrap")` is nil
- WHEN a sandbox rule matches
- THEN the hook returns `(:confirm t)`.

### Requirement: srt backend (opt-in)
The wrapper SHALL support `srt` as an opt-in backend: when
`gptel-permit-sandbox-backend` is `srt` (or `auto` resolves to it), the
wrapper SHALL write a settings file mapping `gptel-permit-sandbox-writable-dirs`
to `filesystem.allowWrite`, protected paths to `filesystem.denyRead`/
mandatory denies, and `gptel-permit-sandbox-allowed-domains` to
`network.allowedDomains`, via `json-encode`, and wrap the command as
`srt --settings FILE COMMAND`.

#### Scenario: Settings reflect defcustoms
- GIVEN writable-dirs ("~/proj/") and allowed-domains ("github.com")
- WHEN the srt settings file is generated
- THEN its JSON contains filesystem.allowWrite ["~/proj/"] and
  network.allowedDomains ["github.com"].
