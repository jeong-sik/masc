# Resolve stored-state deployment refusals

`scripts/install-local-build.sh` checks `runtime.toml` and replaces binaries.
It does not scan stored history. Use the candidate build's
`deployment_preflight_helper.exe validate-stores` explicitly when inspecting a
storage-format change or investigating a runtime refusal. The full deployment
gate, including the container entrypoint, still runs this scan before startup.
Installing binaries does not prove that saved state is compatible; startup and
the stores' runtime readers keep their own refusal policies.
Normal startup reads only its boot-policy stores. `Preflight_only` stores are
first read by their runtime consumers, so local installation and startup do not
audit them. For a storage-format change, follow its **Fresh state required**
entry and run the full check explicitly before restarting.

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
does not persist between scope scans or helper invocations.

The helper reads one store after another in its own process. `--jobs N` reads
up to N stores at once, each in its own process. A store's `scan_started` line
prints when its read begins. Its `scan_elapsed_s` line and report print in
store order, after the reports of the stores before it, whatever N is.

`scan_failed` means the scan could not complete; it is not an empty store.
`first refusal` is one example, not an inventory of every affected file.
`on refusal` describes what the running server does with such a row.

The `memory OS current snapshot` scan also reports `pending recovery` for a
readable publication receipt. That receipt is current state, not a decode
refusal. The full scan reports failure while recovery is pending; the running
owner finishes the publication. Local binary replacement does not wait for
this audit.

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
installer resolves:

```sh
_build/default/bin/deployment_preflight_helper.exe validate-stores \
  --base-path /path/to/workspace
```

## What goes with each store

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
`fresh state` line names both scope directories.

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
