# Reentrant official-client receipt release

Parent: `df06c35a0cebdccca057a8bc55313d219a18e46b`.

The release observer can yield or reenter while an asynchronous tool commits
another receipt. The old Holding -> Delivering transition happened before
the held batch was notified, so a new receipt notified immediately and
overtook earlier commits. This affects the shared official-client receipt
owner; Muse uses its Held_until_released mode.

The state now includes Releasing with a FIFO queue. New commits append to
that queue; nested release does nothing. Delivering begins only after all
queued receipts are attempted. On observer failure, the attempted receipt
is ambiguous and is not replayed; unattempted queued receipts are preserved
in Holding for later explicit release. Failure/cancellation is rethrown.
This does not create another invocation or execution identity authority.

## Executed proof

OCaml 5.5.1 interpreted the **entire production module** using #use, with
explicit doubles for external hook types, execution joins, Ids and Eio_guard.
The receipt state, bind/commit/start/finish/release and notification logic
are the real source. Eio_guard is a synchronous Fun.protect double; actual
Eio cancellation, full integration typing and HTTP/UI are not proven.

```
python3 docs/evidence/2026-10-12-tool-receipt-release-order/run.py \
  lib/keeper/keeper_official_client_tool_receipts.ml
```

The same harness loaded the parent module extracted with git show. Parent
returned exit 1: observed `a,c,b`, violating commit order. Current source
returned exit 0: `a,b,c`. A second current-source scenario verifies a failing
notification retains unattempted `b,c`, does not retry the ambiguous `a`,
ignores nested release and delivers a later `d` immediately. Logs and exact
source/artifact SHA256 values are stored beside this document.

Implementation/interface syntax checks and git diff --check returned 0.
No Dune build or CI was run. Live provider, installed runtime, screenshot
and formal approval remain unverified.

## Remaining boundaries

Reentrant receipts in already-immediate delivery and failed notification
acknowledgement need separate treatment; this change certifies held release.
The hypothesized ordinary same-MCP-call finish during its start callback is
not reachable through the inspected normal HTTP handler: tool.call starts
after on_tool_started returns, and finish runs afterward in finally. Native
Serve events are read on one loop. Do not add another replay/finish registry
based solely on an artificial same-call callback injection. Actual yielding
held receipt release has the demonstrated counterexample above.
