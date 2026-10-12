# Input reconciliation and queue ownership

Base: `4e133b729764b176464cb5b3b0b7125e82978f03` (#42522).

Local/server input replacement still indexed keeper + raw request/phase/position after anchors gained typed ownership. A persisted foreign or unknown-source user row with the same textual slot could remove the local input. Queue visibility separately hid any row whose raw ID occurred in the operation queue, including foreign/unknown source rows.

One `chat_operation_input_slot` now supplies observed Operation identity for reconciliation, anchor creation/matching and renderer search slot keys. Session slots use exact Session identity fields; persisted slots use their producer fields. The actual Operation owner must agree with that request. No unknown or autonomous source grants a local/server input alias. Queue filtering applies only to the reported Operation source ID. It does not infer source from speaker or body.

Executed unchanged extracted production `chat_timeline` plus new shared helper in a minimal typed interpreter harness. The final chat_timeline_slots assembler is an identity stub: checks measure reconciliation/visibility before assembly, not final ordering. Parent exit1 (foreign source consumed local input); current exit0 for autonomous/unknown reconciliation and queue isolation, real server/local Operation replacement, real queued Operation suppression and keeper isolation. Artifacts: `/tmp/masc-tui-input-reconciliation-source-20261012/`.

Three changed OCaml files passed syntax-only parsing; diff whitespace passed. Registered state fixture checks retained/suppressed counts, not layout or order, and remains unexecuted. Full assembly/search-index/typechecking/runtime/screenshots/CI/formal approval/merge are unverified. Primary row identities and remaining queue/ingress paths still require audit; broad goal remains active.
