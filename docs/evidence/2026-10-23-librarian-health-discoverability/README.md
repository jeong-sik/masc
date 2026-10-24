# Librarian health before memory contents

On 2026-10-23, the installed Lab → Keeper memory health page rendered all Keeper
memory contents and the workspace ledger before its health panel. Its page text
contained 2,743,908 characters. The unread and continuity metrics existed in the
DOM, but the initial viewport showed memory contents. Reaching the metrics
required scrolling past those contents. `dashboard/src/components/lab.ts` on
base `e09b9c981afb16843c071366c5d9724fd4026d96` has that same composition.

The change renders the existing `KeeperMemoryHealth` first, followed by the
existing context and ledger panels. No metric, fetching policy, or memory
selection changes. This addresses discoverability in issue #38062's I4 work.

## Direct installed observation

[The screenshot](installed-memory-health.png) was captured through the live MASC
browser connection after scrolling to the metrics. It shows:

- unread turns `?`, preserving unknown data;
- continuity behind `598 (13 못 잼)`;
- stopped Librarians `0`, Librarian failures `4`;
- an explicit server/dashboard source mismatch banner.

The separately read HTTP response `keeper.memory_os.current_health.v8` reported
`librarian_unread_turns: null`, `librarian_continuity_unread_atoms: 598` and
`librarian_continuity_unmeasured: 13`. UI and API observations are separate
requests; they are not an atomic snapshot.

`/health?full=1` returned HTTP 200 with overall health `degraded`, server source
`107c58401723313611f7c599bbe15225de5910da`, binary SHA256
`179f2021ecb4d56474f3fa804d332fc5330f745bc4ca66afd73d85d9da421783`, and
dashboard source `25faf14776f1115e962a4c4873e668af386211ad`. That installed pair
does not verify the candidate source. `observation.json` preserves identities
and artifact digests without publishing Keeper memory contents or credentials.

## Verification boundary

The ordering change was inspected directly and checked with `git diff --check`.
No UI text/order test was added, per the constitution. No Dune build, full CI,
installation, restart, or live configuration change was performed by this task.
The browser tab created for inspection was closed afterward.

The screenshot is a before-change installed observation after manual navigation;
it is not an after-change acceptance screenshot. A matching installed pair,
controlled Librarian stop with visible lag within one turn, TUI evidence, actual
model/JEV evaluation, official-client continuation proof and configuration
transition remain separate requirements. This PR does not close #38062 or
authorize removing its remaining global context marks.
