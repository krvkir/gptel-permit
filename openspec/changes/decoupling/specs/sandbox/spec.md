# sandbox Delta

## MODIFIED Requirements

### Requirement: Sandbox action
The `sandbox` rule action SHALL be provided by the `gptel-permit-sandbox`
module, which SHALL register its handler in `gptel-permit-action-handlers`
at load time; the core rule engine SHALL contain no sandbox-specific code.
When a sandbox rule matches an execute-group tool call, the hook SHALL return
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

## ADDED Requirements

### Requirement: Sandbox self-registration
Loading `gptel-permit-sandbox` SHALL add its action handler to
`gptel-permit-action-handlers` and SHALL add
`gptel-permit-sandbox--post-tool` to `gptel-post-tool-call-functions`;
both registrations SHALL be idempotent across reloads. Removal SHALL NOT be
tied to `gptel-permit-mode`: with the mode off the post-tool tracker SHALL
be inert (no wrapped commands exist to attribute). When the sandbox module
is not loaded at all, a matching sandbox rule SHALL fail closed with
`(:confirm t)` via the engine's unregistered-action handling.

#### Scenario: Load registers both integration points
- GIVEN the sandbox module has just been required
- THEN `(assq 'sandbox gptel-permit-action-handlers)` SHALL be non-nil
- AND `gptel-permit-sandbox--post-tool` SHALL be present on
  `gptel-post-tool-call-functions`.

#### Scenario: Reload stays single-registered
- GIVEN the sandbox module is loaded twice
- THEN the registry SHALL contain exactly one `sandbox` entry and the hook
  exactly one `gptel-permit-sandbox--post-tool`.

#### Scenario: Sandbox rule without the module
- GIVEN `gptel-permit-sandbox` was never loaded
- AND a matching rule with `:action sandbox`
- WHEN the call is processed
- THEN the hook SHALL return `(:confirm t)` and log the missing handler.
