# Muse completed lifecycle across item kinds

Base: `4cf940e39624dba34663f8203808d0b93226a9cb`.

Completion authority previously retained agent items only. Native tool completion
replay was treated as a new single-shot call, emitting another start/finish and
incrementing tool_calls. Compaction completion replay published the observation
again. These are producer-side effects, independent of UI replay handling.

Turn state now owns one completed_items ledger for all decoded item kinds. Every
first completion records its typed snapshot before incoming-kind effects.
Identical replay is a no-op; changed snapshot or restarted completed ID rejects.
All delta fields check completed ownership before field dispatch, so output and
summary deltas cannot bypass the terminal identity check. Supported live text
behavior remains unchanged; other live delta fields retain existing no-op policy.
First single-shot native completion is still accepted exactly once.

Added wire fixtures cover completion replay with and without preceding native
start, completed native restart, and duplicate compaction completion with one
observation. Fixtures were not executed. Syntax-only parsing and whitespace
checks passed. No Dune build, CI, formal approval, installed runtime or screenshot
verification is claimed. Independent source review requested.

Completed snapshots retain turn-local payloads; no arbitrary cap or retention
heuristic is introduced. Delayed-first-completion chronology and full multi-runtime
continuity/UI evidence remain incomplete.
