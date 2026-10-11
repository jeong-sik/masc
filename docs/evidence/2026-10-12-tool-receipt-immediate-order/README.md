# Immediate receipt notification ownership

Parent: `7943e34d8760152de4ed8907295da3d25596bafa`.

Held receipt release already queued reentrant commits, but already-immediate
delivery still called notify recursively. A yielding observer could receive a
newer callback before recording the current receipt. This affects Immediate
mode and the shared owner after held release has completed.

Both paths now use the same Notifying FIFO owner. Reentrant commits queue,
nested release is inert, and callbacks run after the previous callback returns.
Delivering owns the idle/pending queue rather than bypassing it. If a callback
fails, its attempted receipt stays ambiguous and is not retried. Held release
retains unattempted receipts in Holding; immediate delivery retains them in
Delivering so the next commit resumes them before its own receipt. Explicit
release also resumes this pending queue. Invocation and execution identities
are unchanged; no second registry or time/count gate is introduced.

## Executed evidence

```
python3 docs/evidence/2026-10-12-tool-receipt-immediate-order/run.py \
  lib/keeper/keeper_official_client_tool_receipts.ml
```

OCaml 5.5.1 interprets the entire real module using #use. External hook types,
joins, Ids and Eio_guard are explicit doubles; actual Eio cancellation and
integration typing are not proven. The production receipt state and
start/bind/commit/finish/notify/release code are executed.

The same final harness loaded the exact parent source extracted by git show:
RED exit 1, immediate order `b,a`. Current source: GREEN exit 0, order `a,b`.
Executed cases also cover prior held-release order and failure retention,
immediate failure recovery by next commit, and explicit-release recovery.
Both recovery cases attempt `a,b,c` once in order. Logs and SHA256 receipts
are stored here. Interface/implementation syntax and diff whitespace checks
returned 0. No Dune build or CI was run.

Live Eio scheduling, real HTTP tools, installed TUI/dashboard screenshots,
formal review approval and merge remain unverified. Callback cancellation or
failure can leave the attempted notification's delivery ambiguous; this code
does not invent acknowledgement or retry that effect.
