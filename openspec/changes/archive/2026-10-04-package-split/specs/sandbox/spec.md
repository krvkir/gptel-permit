# sandbox Delta

## MODIFIED Requirements

### Requirement: Sandbox package layout
The sandbox capability SHALL be distributed as the `gptel-permit-sandbox`
package: the sandbox core (`gptel-permit-sandbox.el`) plus the two
shipped backend modules (`gptel-permit-sandbox-bwrap.el`,
`gptel-permit-sandbox-srt.el`) in one package, because both backends
`require` the sandbox feature and self-register in its registry, and the
sandbox core loads them lazily by feature name
(`gptel-permit--sandbox-backend-features`).

The backend modules SHALL keep their self-registration and lazy-load
behavior unchanged; a staged install SHALL resolve them exactly as the
repo tree does today (the backend files sit next to the sandbox core in
the staged install).

- The sandbox core's `Package-Requires` SHALL name `emacs`, `gptel` and
  `gptel-permit` only — no sibling package is required by it.
- Activation remains a load of the sandbox feature: a `sandbox` action in
  force while none of the package's files has been loaded remains a
  registry miss failing closed.

#### Scenario: Sandbox package files resolve lazily in a staged install
- GIVEN the staged `gptel-permit-sandbox` install (three files, only the
  core package and gptel on the load path)
- WHEN the sandbox core resolves `auto` on GNU/Linux
- THEN the `bwrap` feature SHALL be `require`d from the same staged
  directory, SHALL register its class in
  `gptel-permit-sandbox-backends`, and the wrap SHALL proceed as in the
  repo tree.

#### Scenario: Sandbox core names no sibling in code
- GIVEN the sandbox core file
- THEN it SHALL contain no reference to any `gptel-permit-judge` or
  `gptel-permit-analytics` symbol (docstring prose is permitted), and it
  SHALL stage-compile with only the staged core on the load path.
