# Telegram prepared ingress claim — 2026-10-25

Source base: `4e5157beba106381a417a4f64ce273875c4623b8`, PR #45831.
An independent [bounded SQLite finding](https://github.com/jeong-sik/masc/pull/45831#issuecomment-6387154730)
and [change request](https://github.com/jeong-sik/masc/pull/45831#pullrequestreview-5639107412)
identified a real custody gap. After A durably accepts an update, final cursor
publication can fail. A later binding to B allowed the same bot/generation/update
operation ID into B's independent store. Per-Keeper uniqueness cannot deduplicate
across those two databases. The external fixture's 24 checks were not executed
or locally inspected by this session and are not counted as our runtime proof.

## Prepared ownership boundary

Before Gate dispatch, the authenticated bot's claim root stores the complete
canonical prepared request: original Keeper, content, caller fields, metadata,
continuation, generic surface, conversation/external IDs and bot/update identity.
The operation ID is the existing Custody bot/generation/update identity; it is
not changed to include a Keeper. Its SHA-256 selects a filename only. Admission
compares the complete canonical value, never a partial route or hash receipt.

A shared durable claim lock serializes the first write and retries. Missing
claims are strictly written before any Gate call. Existing equal claims must
resync their file and parent before use; different recipient/payload/delivery
is a conflict and cannot be overwritten. Read, decode, write, sync and lock
failures never fall back to the current recipient. A previously claimed update
cannot become an ignored update after unbinding or a payload change. Structural
Gate refusals are classified before claiming, so unsupported/oversized new input
keeps its explicit ignore semantics. A conflict remains owed rather than being
silently acknowledged; restoring the original binding permits the exact retry.

Claims reject invalid UTF-8, JSON errors, duplicate/unknown wrapper fields and
noncanonical identity input. The local durable decoder does not use REST UTF-8
repair. Strict shared atomic replacement and file+parent resync are reused; no
new persistence protocol, work expiry, runtime count limit or compatibility
fallback is introduced. Claims are bot-scoped alongside the resolved cursor.

## Validation scope

Six new/changed OCaml source/interface files parse; whitespace checks pass.
No local Dune build or passing execution of this repair is claimed yet.

The new Owner fixture uses actual A/B Owner registry installation, real binding
storage, Gate/Owner admission and durable operation databases. It injects a
failed final cursor write after A acceptance, closes/reopens the registry/stores
and reopens cursor/claim state, changes the binding to B and requires A1/B0 with
no B dispatch. An original-A retry control then confirms custody without adding
an operation. Native fixtures cover payload/recipient/unbound conflicts,
uncertain visible writes, failed and successful resync, duplicate/corrupt UTF-8
claims, and persistence failure before Gate. These scenarios remain unexecuted
at this artifact entry and use injected Bot API HTTP, without a real model,
Telegram account, process crash or deployed server.

Earlier Owner/native/custody/surface successes certify their recorded sources;
the changed ingress path requires new execution. The prior lower SOURCE PASS was
explicitly retracted after the new finding. All current stack heads and full diffs
need new review after restacking. No merge, external delivery or issue closure
is claimed here.
