# Common Pitfalls

Recurring mistakes from commit history analysis. Check this before submitting PRs.

## 1. Stale References After Deletion (12 occurrences)

When you delete or rename a module, these are often left behind:
- Test files referencing the deleted module
- `dune` file listing the deleted module name
- CSS imports in dashboard components
- Other modules that `open` or call the deleted module

**Before deleting any `.ml` file:**
```bash
# Find all references
rg "ModuleName" lib/ test/ bin/ dashboard/src/ --type-add 'dune:*.ml' -l
```

**Before deleting any `.css` file:**
```bash
rg "filename.css" dashboard/src/ -l
```

## 2. Eio Cooperative Scheduling (10 occurrences)

This codebase uses Eio (OCaml 5.x cooperative concurrency). Common mistakes:

- `Stdlib.Mutex` in Eio context → use `Eio.Mutex` (causes EDEADLK)
- Blocking I/O (`Unix.read`, `open_in`) in Eio fibers → use `Eio.Path` or `Fs_compat`
- Missing `Eio.Cancel.Cancelled` guard in exception handlers → re-raise it
- Spin loops (`while true`) → use `Eio.Time.sleep` or `Eio.Condition`

**Exception handler template:**
```ocaml
(try some_operation ()
 with
 | Eio.Cancel.Cancelled _ as e -> raise e  (* always re-raise *)
 | exn -> Log.error "failed: %s" (Printexc.to_string exn))
```

## 3. Dashboard Changes Need Build Verification (38% of recent commits)

Dashboard is a Preact+HTM SPA compiled with Vite. Common issues:
- Nullable fields from API → guard with `?? default` or optional chaining
- Signal updates with same value → cause unnecessary re-renders (use `if (sig.value !== newVal)`)
- CSS custom properties must be defined before use

**Always after dashboard changes:**
```bash
cd dashboard && npm run build  # catches TypeScript errors
```

## 4. Test Breakage From Refactoring (6 occurrences)

Tests break when:
- Module is deleted but test still references it
- Function signature changes but test uses old signature
- Eio context required but test doesn't wrap in `Eio_main.run`

**After any refactoring:**
```bash
dune build --root .  # catches compilation errors in tests
```

## 5. Version String Drift (2 occurrences)

`dune-project` version and `sdk_version.ml` (or equivalent) must match.
CI checks this — but fix it before pushing.

```bash
# Check
grep '(version' dune-project | head -1
grep 'let version' lib/sdk_version.ml
```

## 6. Prompt Changes Need Checkpoint Reset

Keeper system prompts are cached in checkpoints. After changing prompts:
- Existing keepers continue using the old prompt from checkpoint
- New prompts only apply when `build_turn_prompt` overrides at runtime
- If testing prompt changes, verify the running keeper's actual system prompt
- Core prompt text now lives in `config/prompts/*.md`; Dashboard overrides in `Lab > Tools > Prompt Registry` only change runtime effective text and are persisted to `.masc/prompt_overrides.json`
