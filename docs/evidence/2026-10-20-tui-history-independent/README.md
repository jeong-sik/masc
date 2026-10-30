# Independent TUI history and memory delivery

The TUI previously fetched aggregate chat history, then the memory journal, and
sent a single combined result after both finished. This layer starts the same two
readers concurrently and lets the UI admit each actual result independently.
It builds on the response-decoding worker boundary in PR #44369.

Each refresh owns two atomic result slots. A worker publishes its result and
observation clock before returning, without waiting for the shared bounded
mailbox. The existing finite owned-result drain carries the original workspace
and reading epoch to admission. Offering a result does not release its pending
slot: only UI settlement does. The current physical request, history generation,
selected Keeper and workspace admission reject duplicate and superseded results.
Polls retain the other pending source; an explicit refresh owns a new request.
Each source preserves its existing GET and before/after workspace probes, with
an independent identity-contact sequence. Existing workspace job registration and
cancellation remain in place; a cancellation request is not a worker-exit claim.

The saved data also retains its actual source. `keeper_chat_sources` holds the
canonical transcript separately from the memory journal; the existing combined
`msg_loaded` is its presentation/search view. Display role cannot establish
source: canonical system rows can use the Memory role. History absence (`None`)
is distinct from received empty (`Some []`) and remains absent through an early
memory result, a forced replacement or a failed history retry. That distinction
keeps initial pagination setup correct. Older pages update only history; a stale
physical cursor retires history while retaining the journal. Keeper page caching
saves/restores both sources. Single-source views retain their original list.

## Focused evidence

Run from this checkout:

```sh
python3 docs/evidence/2026-10-20-tui-history-independent/flow_probe.py
```

The standalone OCaml probe extracts the production request module, launch body,
owned history collection, source-view setter and source-application arm. Real Eio
fibers/promises show that both GET callbacks start before either returns, and
that the first result is admitted with its sibling still waiting. Eight cases
cover both arrival orders, a canonical row using the Memory display role and
empty/nonempty memory results. Additional cases cover cold memory-first followed
by forced refresh, offered-but-unsettled polling, source failure preservation,
retired physical owners, generation/Keeper/workspace admission, missing switch
and synchronous launch refusal. The checks assert requests, stored data and
decisions, without terminal wording/layout or timing thresholds.

HTTP, workspace probes/admission, typed row projection, row merging and workspace
job registration are fixtures in this probe. The request module, extracted flow
and Eio control flow are real; this is not native MASC linkage or a cancellation
integration test. The probe's fixture state/source types are not the complete
production types. The changed async constructor was also checked in both `.mli`
and `.ml`, and direct consumers were inspected.

Native fixtures now cover real request-owned collection and settlement, workspace
retirement and independent saved-source restoration. The stale-cursor fixture
includes a canonical row with the Memory role so role-based retention cannot
pass it. These fixtures were added/updated and syntax-parsed, **not executed**.
Changed ML/MLI files parse and `git diff --check` passes. No local Dune build,
full/native test run, CI wait, installation or visible TUI latency test was run.

## Review response

The draft independent review found three defects: an omitted `.mli` update,
role-based loss of canonical system rows, and lost initial paging authority after
memory-first plus forced refresh. This layer updates the interface and all direct
consumers, retains real source slots across page lifecycle, and removes the
request-local paging-reset Boolean. Native fixture source seeds were updated too.
The standalone ordering and cold-refresh checks pass after these fixes.

## Remaining scope

This removes the sibling wait and serial request dependency. It does not add a
canonical first-page request, change the aggregate history endpoint, prove faster
server reads, or establish installed TUI paint/input latency. Those require their
own source and installed-runtime evidence.
