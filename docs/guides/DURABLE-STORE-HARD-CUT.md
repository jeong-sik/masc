# Resolve stored-state deployment refusals

`install-local-build.sh` checks stored state with the candidate build's
`deployment_preflight_helper.exe validate-stores`. It changes no installed
binary when this check fails. `rows` is the number examined by a store;
`refused` is the number that its current reader rejected. The final error sums
refusals across stores, not just the last lines printed. A store with
`refused=0` needs nothing because another store failed.

Each store prints `scan_started` before reading and `scan_elapsed_s` when the
read returns, followed by its row/refusal report. Large histories can take time
between those lines. Original-request body decoding is reused within one scope
scan only after freshly read bytes exactly match a previously verified body;
records, scope listings and body bytes are still read on every request. Changed,
missing or unreadable bodies receive the current decoder's refusal. This reuse
does not persist between scope scans or installations.

The helper reads one store after another in its own process. `--jobs N` reads
up to N stores at once, each in its own process. A store's `scan_started` line
prints when its read begins. Its `scan_elapsed_s` line and report print in
store order, after the reports of the stores before it, whatever N is.

`scan_failed` means the scan could not complete; it is not an empty store.
`first refusal` is one example, not an inventory of every affected file.
`on refusal` describes what the running server does with such a row.

The `memory OS current snapshot` scan also reports `pending recovery` for a
readable publication receipt. That receipt is current state, not a refusal: the
running owner finishes the publication, and installation waits until a later
scan passes.

## Fresh state

A build reads only the stored format it writes. State in an earlier format is
not read, converted or migrated. The change that alters a format says what is
no longer read and what to delete in its **Fresh state required** entry in
`CHANGELOG.md` or `changelog.d/`.

1. Stop every server and other writer for the workspace.
2. Delete what the entry names. Lane Add-on stores also print a `fresh state`
   line with the paths to delete.
3. Run the candidate's `validate-stores` again. Every store passes.
4. Install and start the server.

Run the helper from the build being installed, against the workspace the
installer prints:

```sh
_build/default/bin/deployment_preflight_helper.exe validate-stores \
  --base-path /path/to/workspace
```

## What goes with each store

### Keeper chat operation journals

The journal is
`<base-path>/.masc/keepers/<keeper>/chat-operations.sqlite3`
(`Common.chat_operation_store_basename`). Its SQLite sidecars, when present,
are `chat-operations.sqlite3-wal`, `chat-operations.sqlite3-shm` and
`chat-operations.sqlite3-journal` in the same directory. Treat these as one
store, with every writer stopped before any fresh-state removal.

The current semantic record format is
`masc.keeper_semantic_execution.v3`, with explicit `native_calls` and
`receipt_obligations` lists. Earlier records are refused without conversion
or inferred empty history.
Both ordinary open paths check every semantic row, including settled records,
and its indexed scope, revision and phase before configuring the existing
database. Deployment preflight also reads every durable record. Refusal names
the affected scope and codec or index error; no Owner handle is returned to
perform startup settlement or accept new work.

Choosing fresh state for this journal discards the Keeper's queued, running
and settled operations, original inputs and batch-member input history,
semantic continuations, native-call history associations and trace input and
checkpoint ownership references. It does not remove the actual Core journals
under `.masc/traces/<trace>/native-executions/` or retained checkpoint payloads
under `.masc/traces/<trace>/accepted-checkpoints/<sha256>.json`. Once the
fresh journal no longer names those accepted checkpoints, a later startup
sweep may collect payloads no other journal names. Preserve the old journal,
sidecars and dependent session/checkpoint evidence together before choosing
fresh state; payloads left on disk do not restore the removed ownership or
authorize continuation. A separate fresh base path keeps the old workspace
and its ownership records intact. See the
[#50583 fresh-state entry](../../changelog.d/50583.md) for this format change.

### Keeper turn records

Files live under `.masc/keepers/<keeper>/turn-records/YYYY-MM/DD.jsonl`. The
first refusal names the file and line. Raw-trace retention keeps only the raw
traces its most recent turn records name, so the next sweep after a Keeper's
turn records are deleted removes that Keeper's raw traces. Carried-front
recovery and request observation start from the turn records that remain.

### Official-client turn fragments

The files are `.masc/traces/<trace>/history.jsonl` and
`history.internal.jsonl`. The first refusal names the file and line. The pair
is the trace's conversation history and the Librarian's named-turn input.

### Lane Add-on tool request owners

Librarian original executions and absorption gates are owner records under
`.masc/lane-addons/tool-request-owners/<scope digest>/` with request bodies
under `.masc/lane-addons/tool-request-bodies/<scope digest>/`. The check
decodes each record with its body and the consumer's payload decoder, and
follows parent, retry, partition and replacement links inside the scope. It does
not run Memory parts discovery, publication recovery or a provider. Discovery
reads a scope as a whole and fails it on one record it cannot read, so the
`fresh state` line names the scope's owner records, request bodies, history
fences and history resolutions that exist. A scope that no consumer of the
build reads is refused the same way.

A Librarian original's consumer also reads the original's Exact record and
proof file. The check reads them as that consumer does, on the files the
exact-request check below leaves. When the consumer would stop on them, the
original is refused (`consumer Exact reads of the original`). Its `fresh state`
line names, for every scope of the original's owner, the owner records, request
bodies, settled originals, history fences and history resolutions that exist.
When no record of the original is left, the line also names its proof file. A
member of a Closing or Closed admission closure and a fenced history original
are read by no consumer, so neither is refused. A body refusal
(`Request_body_refused`) passes without a record, except for an admission
original whose record the exact-request check deletes: admission reads the
size evidence of that refusal through the record, and without it the part and
every later candidate of that Keeper wait. A proof file that names another
store root stops this check as it stops the exact-request check. Delete the
exact-request lines and these lines together: once both files are gone, the
next check passes two kinds of original it refused. A Dispatch_pending original that
lost its finished record looks like one the host never ran. An admission
original the host ended with the body refusal looks like one the worker
refused before the host.

### Lane Add-on exact requests

Exact request records are
`.masc/lane-addons/exact-requests/<declaration digest>/<request ID digest>.json`.
The original execution proofs of a request are one file under
`.masc/lane-addons/host-results/`, named from the record's declaration ID,
request ID and request digest. Its slot observations are files in the
declaration's observation directory under `host-results`. The check reads a
record, its proof file and the record again, with the decoder the exact lane
uses when it runs the request. A refused record's `fresh state` line names the
record, its proof file and the slot observations of its request. A record
stored at a path its own IDs do not name, a proof file that no record names and
a slot observation the startup sweep cannot read are each refused alone.

Proof files and slot observations name the store root they were written
under. When one names another root than the check reads, the scan fails
(`scan_failed`) with both roots and prints no `fresh state` line: the
workspace was moved or restored, or the check reads another path than the
server serves.
`--base-path` resolves like the server's workspace path, through symlinks, so
the workspace, its `.masc` directory and a symlink to the workspace read the
same store.

### Run registries

The exact-lane, fusion, verification and Goal verification run registries drop
unreadable rows only through compaction, and replay refuses to compact while
one is on disk. With the server stopped, this cuts those rows:

```sh
_build/default/bin/deployment_preflight_helper.exe cut-run-registries \
  --base-path /path/to/workspace --execute
```

Without `--execute` it only reports. A registry whose last line is
unterminated is left alone and reported.

### Goal store paths

A Goal store path that cannot be read, including a dangling link, reports
`inspect_path`; the path, its link target and its mount are where to look. Observed nonregular Goal paths report `nonregular` and
`mirror_nonregular`. These values appear in `.masc/goal-verification-runs.jsonl`
and in the task context of `.masc/keepers/<keeper>/turn-boundaries.jsonl`.
Dashboard and TUI clients read them, so they are updated with the server. An
older build does not read them; installing one is its own fresh state.
