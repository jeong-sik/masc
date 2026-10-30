# Resolve stored-state deployment refusals

`install-local-build.sh` checks stored state with the candidate build's
`deployment_preflight_helper.exe validate-stores`. It changes no installed
binary when this check fails. `rows` is the number examined by a store;
`refused` is the number that its current reader rejected. The final error sums
refusals across stores, not just the last lines printed. A store with
`refused=0` needs no cleanup because another store failed.

Each completed store reports immediately. A scan can still take time before
that store's result appears. `scan_failed` means the scan could not complete;
it is not an empty store or permission to reset it. `first refusal` is one
example, not an inventory of every affected file. `on refusal` describes the
runtime consequence, not an instruction to delete data.

## Inspect the candidate and preserve the evidence

Use the helper from the build being installed, against the resolved workspace
printed by the installer. For a local Dune artifact:

```sh
_build/default/bin/deployment_preflight_helper.exe validate-stores \
  --base-path /path/to/workspace > /path/to/preflight.log 2>&1
```

Keep the exit status as well as the log. A live scan is a diagnosis; writers
can change counts and files while it runs. Before any hard cut:

1. Record the candidate commit and helper identity, workspace, each failed
   store, counts, full file paths and decoder errors. Read the change's
   **Fresh state required** entry in `CHANGELOG.md` or `changelog.d/`.
   Do not infer a schema upgrade from a row count: I/O and malformed JSON can
   also cause refusals.
2. Identify the consumers and work depending on those files. Reconcile pending
   work under a compatible build, or document which work will remain
   unresolved and how a fresh run will preserve its source and evidence.
   A decoder failure does not prove that work completed or that its input was
   acknowledged.
3. Stop every server and other writer for that workspace through normal
   shutdown. Verify that they stopped, then repeat the complete inventory.
4. Back up the complete affected files and dependent state outside the runtime
   tree. Record their relative paths, sizes and checksums, and verify the backup
   by reading it back. Review the exact cut scope and its effect before moving
   anything. A missing upgrade instruction requires a store-specific decision;
   it does not authorize clearing the whole workspace.

Do not add guessed fields to old rows, silently skip rejected rows, or disable
the deployment check to make installation pass.

## Keeper turn records

Store label: `keeper turn records`. Files live under
`.masc/keepers/<keeper>/turn-records/YYYY-MM/DD.jsonl`. The first refusal names
the full file and physical line number. For example, a missing
`request_observations` field means the current decoder requires evidence the
old row did not retain. Inserting an empty array would assert that no request
was observed; the old row does not establish that.

Turn records feed more than display: raw-trace retention, carried-front
recovery and request observation also read them. Preserve referenced traces,
turn boundaries, provider inputs and request receipts. Do not let removal of
a turn-record reference authorize collection of the only remaining raw trace.

After reconciling these consumers and verifying a stopped-writer backup, the
reviewed fresh-state scope may set aside the affected complete daily files.
Mixed files include valid rows too: record that loss of active history and
keep the whole file in the backup. Do not rewrite individual rows or move all
Keeper metadata, memory snapshots, queues or session state along with them.

## Official-client turn fragments

Store label: `keeper official-client turn fragments`. The source files are
`.masc/traces/<trace>/history.jsonl` and `history.internal.jsonl`. The first
refusal names the exact file and physical line number. For example, missing
`origin` means a message lacks provenance the current reader requires. Do not
invent an origin or remove its `turn_ref` to make it untagged.

These files are also conversation history. The Librarian consumes named-turn
fragments using turn boundaries and durable progress; moving history alone
can make unconsumed material disappear from its input. Preserve the complete
session, its history pair, boundary records, Librarian progress/range receipts,
current memory and any admission originals, proofs and ACK state that refer
to it. History rejection is not evidence of successful absorption.

Resolve unconsumed turns under a compatible reader before cutting history.
If that is impossible, record them as unresolved and review a fresh session
and its dependent Librarian state together. Only then set aside the reviewed
history scope while stopped. Do not clear all traces or reset a cursor to
pretend the old input was consumed. This guide intentionally provides no
blanket move command: the correct session and progress scope depends on the
persisted bindings, not just the first failed file.

## Librarian original executions and absorption gates

Store label: `lane-addon tool request owners`, decoder `consumer original
request payload`. A readable generic owner envelope and matching body digest
do not establish that this build can read the Librarian payload. Admission
executions require schema 2 with captured admission and retirement policy;
all admission, completed-history and message-floor absorption gate requests
require version 3 with captured guidance. Execution schema 1 and gate version
2 have no reader or automatic conversion in this build.

The refusal names the owner record's full path, scope, request ID, request
digest and decoder error. Owner records live under
`.masc/lane-addons/tool-request-owners/`; the named complete bodies are separate
files in that store. The check includes historical gate records, full gate
preparations retained by execution parents, and digest-only retry bodies that
have not yet acquired a child owner record. It checks current payload, source
and host bindings through read-only ports, including reciprocal root/retry
IDs and digests, ancestry cycles and unacknowledged child progress. It does
not observe or initialize
today's Memory epoch, run parts discovery or publication recovery, replay a
provider, save Memory, or acknowledge input.

Reconcile the work under a compatible build before cutting state. Review the
complete captured physical workspace/keepers/runtime roots, Keeper identity,
Memory epoch and queue generation, rather than moving only the first refused
file. Preserve the connected scope together:

- Execution originals and their complete bodies, immutable candidate parts,
  two-child partition transactions/children, and replacement/frontier records.
- Admission, history and floor-step gate originals, captured guidance,
  parent judgments and preparation intents, retry predecessors/successors and
  unpublished bodies, plus the host execution/size evidence they name.
- Original pending candidates and their generation/sequence/payload identity,
  Memory commit/publication and admission/range receipts, original source and
  history snapshots/boundaries, source progress, and dependent queue or
  external-cursor ACK evidence.

Parts discovery restores originals before receipt-backed queue ACK. An old
execution or gate can therefore block the complete inventory even when it is
historical. Removing its gate alone can leave a parent preparation, retry or
partition pointing at missing evidence. A refused record, finished worker
reply or delivery receipt does not prove domain completion or consumption.
Record unresolved work explicitly; keep its original source evidence and
pending input instead of manufacturing an ACK or replaying an effect.

Apply the stopped-writer inventory, verified backup and scope review above.
Do not fill missing policy from today's prompts, reset an epoch to hide an
old scope, or clear a complete Librarian worker volume. A clean current-payload
scan is only decoding evidence; actual continuity, execution proofs and
consumption still require their normal authorities.

## Verify and roll back

Re-run the candidate's full `validate-stores` against the stopped workspace.
Every examined store must pass; an interrupted scan is incomplete. Run the
installer again, then start the server and verify the affected Keeper and
Librarian paths with their actual pending work. A clean scan only proves that
the remaining state decodes; it does not prove continuity or consumption.

For rollback, stop all writers first and restore the matching binary and the
complete backed-up scope, including its reviewed dependent state. Reconcile
work that advanced since the backup before enabling execution. Do not combine
old history with a newer cursor or replay a provider effect solely because
the backup restored its request.
