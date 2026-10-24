# Telegram polling custody (#24497, upper layer)

Telegram_rest_client is the transport prerequisite. Telegram_poll_custody owns
one real fetch/settlement step using that client, actual cursor files, the shared
process/fiber durable lock and strict atomic writer. It authenticates getMe and
binds persisted state to that bot ID; token strings/hashes do not identify an
event. Server bootstrap, concrete Keeper acceptor, continuation construction and
outbound delivery remain the next integration layer. This module alone does not
make Telegram continuation work or replace the sidecar.

## Acceptance and persistence

Before a request can acknowledge any earlier update, the cursor is parsed,
validated against the authenticated bot and synced with its parent. A missing
cursor omits offset. Corrupt, wrong-bot and unreadable state refuses polling.

Fetching occurs outside the settlement lock. After fetching, settlement rereads
under the lock, refuses an obsolete generation and skips already committed items
from a stale concurrent page. A new observation is durably recorded before any
accept callback; otherwise a successful submit followed by failed offset storage
would erase the identity epoch needed to distinguish future ID reuse. Each
confirmed receipt or explicit typed ignore then publishes its successor offset
before the next update can settle. The callback must only enqueue durable work;
it must not execute models or deliver replies while holding the transaction.

A receipt must identify the original operation ID, Keeper destination and
Telegram channel. Missing/wrong receipts, Lost and Acceptance_uncertain stop the
frontier. Confirmed terminal operations remain accepted, independently of model
success. Strict writer errors stop acknowledgment. An after-rename failure may
leave a visible offset; every subsequent read must successfully sync that file
and its parent before using it. Cancellation is allowed while fetching or
waiting for the lock; admitted acceptance/publication uses the existing durable
lock's cancellation protection and structural cleanup. Storage claims follow
Fs_compat's process-restart contract, not hardware/power-loss guarantees.

## Protocol generations

The [official Bot API](https://core.telegram.org/bots/api) says queued updates
are retained at most24h and IDs may randomize after at least one week without new
updates. A page received now may already be a day old, so a persisted offset's
validity ends no later than observation plus (week minus maximum queue age).
This is API acknowledgment validity, not Task expiry or a Keeper runtime budget.

The preparation lock samples trusted UTC after admission and reserves the actual
bounded HTTP window inside that validity. Before the boundary, it durably starts
a fresh generation and omits the old offset. Operation identity includes bot ID,
generation and update ID; reused IDs cannot alias old operations. Generation
observation is recorded before first acceptance, including pending offset=None,
so failed first cursor publication survives a long-idle restart correctly.
Nonfinite/backward clocks and responses outliving their HTTP window refuse
settlement. This policy assumes the supplied UTC clock is trustworthy and the
transport honors its window; no live clock-skew or server-discard experiment
was performed. Negative offsets and destructive queue resets are never sent.

## Verification scope

Root test_telegram_poll_custody has ten groups for partial frontier/restart/token
rotation, wrong/unconfirmed receipts, malformed/wrong-bot state, deterministic
interleaving of a stale page, before-rename publication failure, failed first
commit followed by long-idle ID reuse, after-rename directory-sync recovery,
explicit ignore/overflow, lower/randomized reused IDs, and invalid clocks.
Tests inject completed HTTP and synthetic Keeper operation receipts while using
real cursor files, actual shared locking and atomic writers. Faults are injected
at the existing atomic writer's file/parent sync seams. They are not a real
Keeper store acceptance test, actual multiprocess test or live Telegram call.

The first selected CI40104116658 at568c73d26ab45919b14ac92cd7b23a8422eb1315
failed compiling the Root fixture because its direct Unix dependency was absent.
The stanza now explicitly declares Unix/Eio. [Repaired CI40104873977](https://github.com/jeong-sik/masc/actions/runs/40104873977)
completed SUCCESS at exact code head e10399db446cb90f2865981084787af32bf7f0a4.
Completed logs directly confirm the actual Gate build, six API protocol tests
and ten custody tests PASS. After parent #45813 merged externally as
f31033df4d45a2ee97ec7f86ce149a6a33cff6a1, gh-stack rebased this layer onto main.
The custody/API implementation, interfaces and fixture sources are unchanged;
that run remains evidence at its recorded pre-rebase head. No new-base build
or rerun was claimed from source equivalence alone. OCaml parser and whitespace checks passed. No local
Dune/full regression, installed runtime, actual server ingress/continuation,
sidecar deletion or dashboard proof. #24497 remains open.
