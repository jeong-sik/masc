# Muse failed terminal content closure

Parent: `b9144b9eac9cc3cc8e57135d7362f4da6131f193`.

`Runtime_muse_serve.await_terminal` emits Turn_terminal_received before its
terminal usage report. Failed/cancelled/unknown terminals then return Error;
the later Turn_finished publication is reached only on successful completion.
The adapter previously ignored all Turn_terminal_received variants and closed
native/MCP content only on Turn_finished or host-stop completion. Thus failed
turns could leave admitted native content open. This is source evidence of a
reachable lifecycle omission, not an observed live Muse failure.

The adapter now handles the terminal sum exhaustively. Completed terminal
observations still wait for final text and the existing successful EndTurn.
Failed, cancelled, and unrecognized terminal observations use the existing
idempotent cleanup owner to retire maps, close content, and publish MessageStop
without a fabricated successful stop reason. Subsequent usage callbacks remain
separate and are processed. Runtime failure classification/recovery is unchanged.
No keyword matching, duplicate occurrence registry, or numeric cap was added.

Executed on 2026-10-12, all exit 0:

```
ocamlc -stop-after parsing lib/keeper/keeper_muse_runtime.mli
ocamlc -stop-after parsing lib/keeper/keeper_muse_runtime.ml
ocamlc -stop-after parsing test/test_keeper_muse_runtime.ml
git diff --check
```

These prove syntax and whitespace only. A registered state/protocol fixture
covers all three unsuccessful terminal variants with native and MCP blocks,
duplicate terminal, late finishes, no invented success, and retained usage.
The existing successful projection fixture also supplies Terminal_completed
before final text. These fixtures are **not executed**. Build, typecheck, CI,
installed runtime and screenshots are unverified.

Content starts from an independently running MCP callback after presentation
closure remain a separate lifecycle-admission investigation. This change does
not claim to cancel tool effects or solve all asynchronous callback races.
