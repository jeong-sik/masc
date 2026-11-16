# MASC snapshot callers

This layer uses the Core API from the preceding commit. The five changed source files and validation scope are bound by `caller-proof.json`.

The following paths previously allocated a new `Checkpoint_objects.memo`, passed it to a full load, and discarded it. They now call the named `decode_head_read_only_off_scheduler` helper:

* `keeper_checkpoint_store_load.load_agent_core_as` uses it only for `Read_only`. `Read_for_save` still loads through its memo, publishes the same summary, keeps the same lineage, and returns the same handed-out checkpoint.
* `keeper_checkpoint_store_exact_snapshot.exact_snapshot_of_head_bytes` and the cache-miss branch of `load_ref_and_head_locked` return snapshots rather than encoding memos. Existing canonical-identity reuse and session locks are unchanged.
* `keeper_checkpoint_store_decode.load_agent_core_history_file` returns a historical checkpoint, not its temporary memo.
* `keeper_checkpoint_store_canonical` uses it for full canonical judgment. Object/corruption classification and exception handling are unchanged.

One actual caller is `keeper_librarian_durable_consumer.load_current_checkpoint` → `load_agent_core`. Its `unread_turns` caller checks `may_have_unread` first; this change does not claim that every poll decodes history. It reduces the work of an existing full read, without a new cache, freshness rule, budget, validation exception or source-lifetime policy.

The helper keeps head parsing and complete object decoding in the same CPU-pool submission as before. The Core native fixture runs whole old/new implementations and covers error/result equality and preserved memo behavior; see [README.md](README.md). It does not execute the MASC filesystem/cancellation/worker integration.

All eight relevant MASC ML/MLI files passed syntax parsing. Direct typing with real wrapped Core unit names successfully compiled the actual candidate Codec, Objects MLI/ML, actual `agent_core.mli` alias interface and actual MASC decoder MLI. Typing the decoder ML then stopped because the freshly compiled `Agent_core` interface and the existing prebuilt `Keeper_checkpoint_store_history_files.cmi` have inconsistent interface assumptions. The exact sanitized compiler result is retained in `caller-proof.json`. No invented interface, unsafe coercion, Dune rebuild or wider dependency recompilation was used to hide that boundary. MASC implementation typing and whole-product integration therefore remain unverified locally.
