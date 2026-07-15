## 1. Rule Engine Matching Update

- [ ] 1.1 Modify `gptel-permit--match-rule-p` in `gptel-permit.el` to treat `nil` or missing path-group arguments as `""` (empty string).
- [ ] 1.2 Ensure `expand-file-name` is called on the effective value (now `""` for nil/missing path args) during rule condition evaluation.

## 2. Interactive Rule Creation Update

- [ ] 2.1 Fetch the tool specification inside `gptel-permit-add-rule` in `gptel-permit.el` using `gptel-get-tool`.
- [ ] 2.2 Identify all path arguments from the tool's spec that belong to the `path` group.
- [ ] 2.3 Merge and deduplicate these path arguments with the active argument keys list so they are always selectable in the completions menu.

## 3. Test Updates and Additions

- [ ] 3.1 Refactor `gptel-permit-rule-nil-path-no-match` in `tests/gptel-permit-rule-engine-test.el` to `gptel-permit-rule-nil-path-treated-as-empty-string` asserting a successful match.
- [ ] 3.2 Add a test in `tests/gptel-permit-rule-engine-test.el` verifying missing path arguments also resolve to current directory and match rules properly.
- [ ] 3.3 Verify existing validation tests (`tests/gptel-permit-validation-test.el`) still pass with nil required arguments causing missing-argument blocks.

## 4. Verification

- [ ] 4.1 Run full ERT test suite using `make test`.
- [ ] 4.2 Run interactive compilation using `M-x emacs-lisp-byte-compile` on `gptel-permit.el` to ensure zero compilation warnings or errors.
