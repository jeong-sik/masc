# Input anchor alias retains source identity

Base: `5a54cb497669a9c56ec72e1f78a2520484a52b9d` (#42521).

A local input must survive replacement by its server persisted row, whose ID was not known when submitted. The permitted slot alias used only textual request ID/phase/position. A persisted user row in a different source with the same textual slot could match that local anchor; the renderer search slot index had the same erased source.

The anchor slot now carries the observed journal source. Only a local Session_row whose actual Operation owner equals its session request creates the alias. `same_msg_anchor` requires exact observed source/phase/position. Renderer slot keys preserve that source too. Primary row identity lookup remains unchanged. Unknown source creates no operation alias and cannot match one; no body matching or source inferred from role.

Executed unchanged extracted production anchor type, msg_anchor and same_msg_anchor in minimal typed interpreter surroundings: parent exited1 (colliding autonomous source matched local alias); current exited0 for cross-kind refusal, unknown-source refusal, genuine local/server Operation alias retention and unknown local alias absence. Harness/logs: `/tmp/masc-tui-input-anchor-source-20261012/`. Minimal source/role payload types; no complete search-index execution or clipboard proof.

Syntax-only parsing passed for three changed OCaml files; diff whitespace passed. Registered state identity fixture unexecuted. No full typecheck/build/CI/runtime/search/scroll screenshots/formal approval/merge. Search index memo invalidation still follows projection identity. Primary identity and other consumer boundaries need continued audit; broad goal remains active.
