# Resolve stored-state deployment refusals

`install-local-build.sh` checks `runtime.toml` and replaces local binaries; it
does not scan stored history or restart the server. Its cost should not grow
with every retained conversation, provider input or original request. Local
installation is not a stored-state compatibility verdict.

Before deploying a storage-format change onto existing state, stop the writers
and run the candidate build's explicit audit:

```sh
_build/default/bin/deployment_preflight_helper.exe validate-stores \
  --base-path /path/to/workspace
```

`scripts/check-runtime-deployment-preflight.sh` still runs this audit as part of
the full deployment gate under the workspace writer lease. The container
entrypoint uses that gate. `masc start` and `masc restart` use boot's own store
policies: some stores refuse boot, while `Preflight_only` stores are read only
when their consumers need them. Neither command automatically runs this full
audit. An audit while writers are running is only a live observation; it cannot
certify state written after the scan. No audit moves or deletes stored data.

An incompatible `Preflight_only` queue or journal can block Memory writes or
Librarian progress after the server is already running. The installer does not
detect whether a build changes a stored format. When stored-data readers change,
run the explicit audit; a successful local install does not rule out these failures.

`rows` is the number examined by a store;
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
`masc.keeper_semantic_execution.v4`. Every field is written: the
`native_calls`, `gate_obligations` and `receipt_obligations` lists even when
empty, and `native_call`, `input_response_intent` and `input_branch` as `null`
when there is none. A record that leaves a field out is refused. Earlier
records are refused without conversion or inferred empty history.
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
and its ownership records intact. The #53680 **Fresh state required** entry
in `CHANGELOG.md` or `changelog.d/` describes this format change.

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

### Keeper reaction ledgers

Files live under
`.masc/keepers/<keeper>/reaction-ledger/<generation>/YYYY-MM/DD.jsonl`
(`Keeper_reaction_ledger.store_dir`). A directory of another generation beside
it is not read. The check reads each Keeper's whole ledger with the read the
once-only wakes use. `refused` counts lines that are not JSON and rows the
current decoder refuses. The first refusal names the Keeper's ledger
directory, then the counts and first reason the server logs. An ACK row whose
transition receipt holds a Board stimulus without `audience` (#47996) reports
`first_reason=invalid_transition_receipt`.

The ledger records which once-only wakes were delivered. While a refused row is
on disk, a wake the ledger does not show delivered is not queued. Connector
attention and owned job completions read the whole ledger. Ask answers and
composition completions read it from the UTC day of the answer or submission
on. Choosing fresh state for a Keeper's ledger deletes that record as well. The
next ask answer pass then queues again every answered ask the Keeper's ask
store holds. A first refusal names one Keeper's ledger; run the check again
after deleting it, since another Keeper's ledger may hold refused rows too. A
separate fresh base path keeps the old workspace and its ledgers intact.

### Lane Add-on tool request owners

Completion review, Goal proof review, Candle appraisal and media reading
originals are owner records under
`.masc/lane-addons/tool-request-owners/<scope digest>/` with request bodies
under `.masc/lane-addons/tool-request-bodies/<scope digest>/`. The check
decodes each record with its body and the consumer's payload decoder. It does
not run a provider. Discovery reads a scope as a whole and fails it on one
record it cannot read, so the `fresh state` line names the scope's owner
records and request bodies that exist. A scope that no consumer of the build
reads is refused the same way, unless it is a retired scope
`Server_tool_request_consumer` names; a record of a retired scope passes when
its body restores.

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
`mirror_nonregular`. These values appear in `.masc/goal-verification-runs.jsonl`.
The Dashboard reads them, so it is updated with the server. An
older build does not read them; installing one is its own fresh state.

### Execution journals

An execution journal is an `events.v1.wal` file. A Keeper request keeps one at
`.masc/keepers/<keeper>/request-executions/<call ID>/journal/`, and a native
call keeps one at `native-executions/<call ID>/` under its session directory,
for example `.masc/traces/<trace>/`. `validate-stores` does not scan them. The
reader accepts a stored event only when its bytes equal what the current
encoder writes, so a journal that spells `reasoning_prefix` as an explicit
`null` is refused with `Corrupt_store` and `event bytes are not canonical`
when its execution is read. A finished execution's history then fails to load,
and an operation whose native call was still running when the server stopped
is settled with an unknown effect at startup. Nothing has to be deleted. This
lists the affected journals:

```sh
rg -a -l -F --hidden --no-ignore --glob events.v1.wal \
  '"reasoning_prefix":null,' /path/to/workspace/.masc
```

Delete the `<call ID>` directory that holds a listed journal only when that
execution's history is no longer needed.
