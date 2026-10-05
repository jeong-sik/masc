## What

Two follow-ups from review 5414015306 (context-reviewer) on #41229 (merged as `7c5f73510559153791c9bd969d7ed478661bacda`):

**P3-1 — typed result (task-2069).** `Keeper_shell_tool_command.reject_duplicate_paths` raised `Failure` from inside the declaration table's `lazy`. A bad tool file (two `shell_command` declarations on the same path) therefore poisoned the `lazy`: the first shell command raised, and every later `Lazy.force` re-raised the **cached** exception, taking the whole shell command surface down.

- `reject_duplicate_paths : (string list * string) list -> (unit, string) result` — no raise.
- New `declaration_error : string option Lazy.t` — the duplicate refusal of the embedded table, or `None`.
- `rewrite` answers `declaration_error` as a typed `Error` **before any lookup**, so every shell line gets the same named refusal instead of an exception.

**P3-2 — real TOML load path (task-2070).** The duplicate was only exercised with hand-built lists. New `declarations_of ~read ~files` (the shape `Tool_definition_toml.validate_embedded` already takes) lets a test drive the same `tools/*.toml` load path with two real TOML definitions that declare the same `shell_command`, and asserts the refusal names the path and both tools.

The real crunched tree declares no duplicate, so the shell surface is unchanged.

## Why

The reviewer asked for the failure to be observed at start/load time **or** as a typed result; this takes the typed-result path, and covers the load path directly rather than only a hand-built list.

Verified that OCaml's `Lazy` caches the exception (a thunk that raises runs once; the second force re-raises without re-running), which is the premise of P3-1.

## Evidence

- `dune build test/test_keeper_shell_tool_command.exe` → exit 0
- `dune build lib/` → exit 0
- `./_build/default/test/test_keeper_shell_tool_command.exe` → `[test_keeper_shell_tool_command] all tests passed`, exit 0
- The duplicate test asserts `Error message` (non-empty, naming path + both tools) instead of `exception Failure`; distinct paths (including a prefix relationship) still stand; `Lazy.force declaration_error = None` on the real tree.
- The new load-path test parses two real TOML definitions through `Tool_definition_toml.load` and asserts `declarations_of` returns both `(["board";"list"], …)` entries, then that `reject_duplicate_paths` refuses them.

## Scope

`lib/keeper/keeper_shell_tool_command.{ml,mli}`, `test/test_keeper_shell_tool_command.ml`. No behavior change on a well-formed tree.

## Boundary

Local lane runs, not GitHub CI receipts. This session changed the PR's judged content, so it does not write the verdict line; a different keeper must review.

— indie-geek-blue
