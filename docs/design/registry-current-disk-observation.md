# Current disk observation before original receipt delivery

Curator's retained observation intents need the actual latest registry lifecycle,
including its full registration. A missing entry in the bounded memory projection
does not establish absence. The older completed-only lookup also deliberately
returns `None` for a registered but running request. Neither can decide whether
delivery may publish a registration or completion.

`Run_registry_core.Make.read_current_from_log` performs a fresh full scan under
the registry mutation serializer. `Ok None` means no registration for the requested
ID in that current source, including an initial ENOENT. `Some entry` preserves the
full latest registration and either `Running` or the actual stored `Completed`
payload. A later registration resets the lifecycle. Available JSON null remains a
value. The reader does not shed payloads, reuse an append-prefix cache, or convert
a running row into a synthetic restart completion.

Every complete row is decoded, including unrelated rows. Registration identities
are retained to reject any orphan completion, while only the selected entry's full
payload is retained. Invalid JSON, an invalid event, an orphan completion, an
unterminated fragment or a changing source refuses the whole observation. Startup
diagnostics remain separate: a volatile store, an instance created without replay,
and a malformed/incomplete startup replay cannot borrow authority from a readable
live projection.

The filesystem port `fold_private_jsonl_locked_result` streams complete rows with
the existing private JSONL path mutex and shared data-descriptor lock. The bound
regular descriptor must match the path target before and after the scan, and its
device/inode, size, mtime and ctime must remain unchanged. A symlink to a regular
target retains the existing reader contract. The reader keeps a fixed read buffer
and the current row rather than copying the whole log; Core additionally retains
the registered ID set and one selected full entry. Thus work still scales with
current history size and the largest row. No cache or arbitrary history cap hides
part of the source.

The new filesystem error union is separate from the existing rows/window/tail
readers. Their contracts are unchanged. `completed_from_log` also keeps its
existing create-instance and missing/running semantics for Fusion's delayed
terminal lookup.

This API is a read snapshot. It does not append, compact, truncate, chmod, repair,
fsync, change the live projection or acknowledge an Owner intent. It cannot prove
that a previously observed uncertain append is durable. It cannot reconstruct
history that startup compaction already removed. The later conditional port must
reacquire the serializer, revalidate current source and full available payloads,
settle publication durability, and preserve restart/retention evidence before an
Owner ACK. Callers continue to own the registry exclusively, as required by replay.
No model, worker or domain effect is authorized by this observation.

The focused `test_run_registry_current_disk` source covers the public disk-backed
Core lifecycle, shed versus full payloads, available null, readiness and legacy
lookup, real absence/nonregular/I/O failures, unrelated corruption/orphans/tails,
unchanged bytes/mode, startup diagnostic retention, synthetic-memory versus actual
disk state, a same-inode prefix rewrite, large streamed rows, regular symlink
targets, descriptor/path replacement during the fold and concurrent completion.
Parser checks and source review are separate from compiled execution. This unit
does not complete E02, G03, provider execution, UI observation or installation.
