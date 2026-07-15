## Context

Currently, `gptel-permit` performs validation of arguments and then applies rule-matching. 
If an argument (such as a path-related parameter) is omitted or set to `nil` in the tool call, `gptel-permit` excludes it from condition evaluation. While this is appropriate for non-path strings or numbers, path-related parameters are often implicitly understood to target the "current directory" or "current project root" when empty. Furthermore, during rule creation, users cannot create rules targeting a missing or nil argument because `gptel-permit-add-rule` only enumerates arguments present in the actual tool call plist.

## Goals / Non-Goals

**Goals:**
- Treat missing or explicitly `nil` path-semantic arguments as `""` (empty string) specifically during rule matching, allowing path expansion to resolve them to the current `default-directory`.
- Allow users to interactively create rules on path-semantic arguments even if those arguments are missing/nil in the tool call that triggered the overlay.
- Keep structural validation (`gptel-permit--validate-args`) completely unaffected; missing mandatory arguments should still fail validation and trigger a block.

**Non-Goals:**
- Do not affect `nil` handling for non-path arguments (like `:command` or `:query`).
- Do not change the overall validation hook execution order or API boundaries.

## Decisions

### Decision 1: Handle Empty Path Argument in Rule Matching Loop
- **Option A (Normalize at Enrichment)**: Pre-populate and enrich the plist in `gptel-permit--enrich-tool-call` by adding `""` for any missing or nil path argument.
  *Pros*: Centralized normalization.
  *Cons*: Pollutes the actual tool call arguments list, potentially causing unexpected side effects in other hook functions or custom user handlers.
- **Option B (Normalize in Match Loop - CHOSEN)**: Only normalize missing/nil path arguments inside the condition matching loop of `gptel-permit--match-rule-p`.
  *Pros*: Extremely safe, scope-limited, zero side effects on the original tool call plist or validation.
  *Cons*: Localized only to the matching loop.
- **Rationale**: Since we want to ensure we don't interfere with standard validation or other hooks, handling the empty path mapping inside `gptel-permit--match-rule-p` is the cleanest and safest option.

### Decision 2: Dynamically Populate Missing Path Arguments in Rule Menu
- **Option A (Only display present args)**: Keep current behavior. (Fails to meet requirements).
- **Option B (Expose all spec args)**: List all arguments defined in the tool's specification.
  *Pros*: Complete flexibility.
  *Cons*: Clutters the menu with completely irrelevant optional args (like `:start_line` or `:end_line` for Read).
- **Option C (Expose present args + missing path args - CHOSEN)**: Fetch the tool's full spec, check which of its arguments belong to the `path` group in `gptel-permit-tool-groups`, and inject them into the choices list.
  *Pros*: Precision. Keeps the menu clean while specifically enabling rule creation for missing path parameters.

## Risks / Trade-offs

- **Risk**: A `nil` path might accidentally match `.*` when a user didn't expect it to.
  *Mitigation*: This is the exact desired behavior. We will document and test this explicitly.
- **Risk**: Suboptimal completion experience if a tool has many path-semantic arguments.
  *Mitigation*: Most tools only have 1 or 2 path arguments, so the menu remains clean.
