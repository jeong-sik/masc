# task-230 rejected-window proof

Base PR head: 73ece6112e27de250b66f7993da9f33595b6ae46.

Implementation:
- `lib/keeper/keeper_codex_runtime.ml` now applies `source_projection` first, then computes `full_bytes` and `Runtime_model_input_tail_window.next_shrink_capacity_bytes` from `projected`, the provider-bound request.
- This charges Gate replay's appended User evidence in the strict rejected-window comparison.
- `lib/runtime/runtime_model_input_tail_window.ml` retains the strict comparison against the measured `messages` argument.

Regression:
- `test/test_runtime_model_input_tail_window.ml` adds `test_next_shrink_accounts_for_gate_replay_projection`.
- The fixture compares a 100+600-byte pre-projection history with the same history plus a 500-byte Gate replay evidence User message.
- The pre-projection list has no safe framed retry; the provider-bound list produces a smaller retry boundary and the projected suffix fits that boundary.

Checks:
- `ocamlformat --check lib/keeper/keeper_codex_runtime.ml test/test_runtime_model_input_tail_window.ml`: passed.
- `git diff --check`: passed.
- `bash scripts/dune-local.sh build test/test_runtime_model_input_tail_window.exe`: blocked by pre-existing PR-base errors in `lib/keeper/keeper_owner.ml:806-889` and `lib/keeper_runtime/keeper_event_queue_persistence.ml:588`; neither file is changed by this task.

Bounded verifier snapshots (all kept below the artifact read limit):
- `artifacts/task-230-keeper-codex-runtime-excerpt.md`
- `artifacts/task-230-runtime-window-excerpt.md`
- `artifacts/task-230-regression-excerpt.md`
