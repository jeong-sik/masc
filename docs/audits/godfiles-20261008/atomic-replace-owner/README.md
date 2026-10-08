# Atomic replacement ownership, 2026-10-09

`Atomic_write` mixed ordinary path-based replacement with capability publication,
mutation leases and recovery obligations. The ordinary prefix/tail consumed none
of the capability machinery. Move that complete 245-line effect unit into
`Atomic_replace`, retaining the shared `Atomic_temp_name` grammar.
The existing public `Fs_compat` API and its type manifests bind directly to this
owner. Its test adapter still injects the real blocking writer into the actual
replacement; the old internal `Atomic_write` ordinary API is removed.

[extraction.json](extraction.json) records the exact parent comparison. The moved
prefix/tail and remaining capability body match the parent apart from the owner
header, a comment and two private names. Temp creation, payload write/close/sync,
rename, parent sync, strict/best-effort/rename-only policy, cancellation cleanup,
backtrace preservation and Eio/systhread dispatch remain unchanged.
`Atomic_write.ml` drops from 2,640 to 2,396 lines. Capability publication/recovery
and its remaining test-support responsibilities are still pending; this is not
completion of that candidate or of the initial 171-file campaign.

## Corrected cancellation contract

The old internal strict-staged doc said cancellation was returned with its
backtrace for later transaction repair. Both internal/public streaming docs also
put callback cancellation into a staged failure. That contradicted the existing
implementation and tests: cancellation cleans the staging file and re-raises
the original exception/backtrace. If rename already happened, the target remains
published. Ordinary I/O failures retain `Before_rename`/`After_rename` evidence.

The new owner and public docs now state the implemented contract. This repairs
false documentation without changing the tested cancellation policy.

## Cold file-ingestion evidence

The existing binary-preview test called three write APIs into one store and read
all references afterwards from that shared store. One writer's stored bytes could
therefore mask another writer's missing publication, regardless of expression
evaluation order. File ingestion now uses a separate fresh store for each payload,
and the existing byte/preview/reference assertions read each reference from the
store that produced it. The original memory-write and durable-write paths still
share their original store; no assertions or payloads were removed.

This is an actual direct consumer of the moved worker-only streaming entrypoint:
`Tool_blob_store.put_file_durable → Fs_compat.write_file_atomic_strict_staged_blocking → Atomic_replace`.
It covers valid Unicode, all byte values, malformed UTF-8 and preview boundaries,
while preserving exact stored bytes. No copy of the replacement implementation
or source-shape regression test was introduced.

## Executed verification

The operator authorized these narrow local checks. [checks.json](checks.json)
records commands, terminal exit codes and executable hashes;
[source-sha256.json](source-sha256.json) fingerprints changed files and real tests,
shared grammar and the unchanged blob consumer.

| Changed contract | Actual verification | Result |
| --- | --- | --- |
| Direct public bindings, types, ordinary and streamed replacement | focused `test_fs_compat.exe` build | Exit 0; [build.log](build.log), empty successful output |
| Failure stages, cancellation, temp grammar and off-fiber/raw-byte writes | existing `save_file_atomic` group | 14 cases passed; [write.log](write.log) |
| Worker-only streamed replacement and cold file-ingestion consumer | focused `test_tool_blob_store.exe` build and existing basic case 3 | Exit 0 and 1 case passed; [blob-build.log](blob-build.log), [blob.log](blob.log) |

Only the 15 actually executed cases are counted. Dependencies compiled as needed
for those targets; this was not an all-target build. The separate rename-only
policy body is source-identical after the declared private rename and typechecked,
but no separate rename-only behavior scenario was run. Other blob, inventory,
concurrency and capability-publication groups, full CI, live startup recovery,
power-loss durability and deployment remain unverified by this slice.
