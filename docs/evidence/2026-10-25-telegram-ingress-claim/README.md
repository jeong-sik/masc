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
The initial entry recorded parse-only evidence. Subsequent execution is separated below; no local Dune build was run.

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

## Focused execution update

[Run 40116879873](https://github.com/jeong-sik/masc/actions/runs/40116879873)
checked out exactly `3fb24f2d0753cbbd60988d20f1b2751adcbdcd0c`.
The native gateway suite passed all 10 cases. The overall run failed because
the new Owner fixture expected `Ok ()` from the binding API, whose success
payload is JSON. No Owner cases executed in this run. The fixture now accepts
that success payload; production code is unchanged. Owner reopen/A1-B0 behavior
still requires execution. The malformed-UTF-8 assertion was already present in executed source 3fb24f2;
only explicit error-match refinements came later. Native10 includes that UTF-8
refusal. Those subsequent exhaustive-pattern refinements were not rerun there.

The external reviewer dismissed the prior change request and recorded a
[source-only resolution](https://github.com/jeong-sik/masc/pull/45831#pullrequestreview-5639183657)
at `61f899c1e6cf2fd79df833189dbc8e6a59ee2e27`. That is not formal approval,
execution evidence or approval for the current complete stack.

## Actual Owner recovery execution

[Run 40117878485](https://github.com/jeong-sik/masc/actions/runs/40117878485)
checked out exactly `f2d8447e218dd222a508cafa81365cc4dc0466c0` and completed
SUCCESS: all 93 actual Keeper Owner cases passed in 2.149s. The log includes
A's real queued operation, B rejection before Gate admission, A1/B0 after
registry/store/cursor reopen, and exact original-A retry confirming custody.
The committed excerpt preserves the checkout and original assertion lines.
This uses actual durable Owner databases and injected Bot API/cursor failure,
not a model call, Telegram account, OS process crash or installed server.

The later documentation-only evidence update does not alter production or
fixture inputs. Native10 and Owner93 remain separate executions at the sources
above. Earlier unexecuted statements describe their initial entries and are
superseded only for the exact observed scenarios, not full native delivery or
original #24497 acceptance. No full regression, installation or merge claim.
