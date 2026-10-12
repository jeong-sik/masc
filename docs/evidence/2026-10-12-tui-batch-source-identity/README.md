# Batch membership retains execution kind

Base: `3fe03a8179e1de98085068896d267c3b4f2c5daa` (#42512).

`selected_source_logs_with_origin` distinguishes Operation and Autonomous_turn, but `chat_execution_member_index` erased that kind and indexed membership by string execution ID. A direct batch whose opaque execution ID equals an autonomous turn key could contribute its follower input to the autonomous member set.

Use existing `execution_source_key` for the member index and require a typed source at both renderer call sites. Derive the canonical display/request ID with the existing journal `source_key`, rather than accepting a second independent ID. Filtered keeper and sorted unique membership semantics remain intact.

Executed unchanged extracted production indexing/key code in minimal typed OCaml state: parent exit1 (autonomous inherited colliding direct input); revised exit0 (source kinds separated, actual direct batch retained, other keeper excluded, duplicate held/inflight log deduplicated). Corrected harness uses real Turn_ref-shaped key `trace#1`; original intermediate current harness is retained separately. Artifacts: `/tmp/masc-tui-batch-source-identity-20261012/`. This is isolated indexing execution, not full application typechecking or a rendered timeline test.

Three changed OCaml files passed syntax-only parsing; diff whitespace passed. Added registered state membership fixture, unexecuted. No build/CI/runtime/screenshots/formal approval/merge.

Known follow-up: `chat_log_timeline_context` still indexes committed rows by raw request strings; renderer block membership/rails also use string keys. Canonical equal IDs are still present in both member lists. This unit separates batch follower membership only and does not claim complete timeline, error or row ownership isolation. Broad input/interleaving/broadcast/async/provider goal remains active.
