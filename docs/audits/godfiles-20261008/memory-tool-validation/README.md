# Memory tool mutation validation boundary

PR #42110. Base 27ac98d0e66f654c66a9509a006ad444af8af73f.
Code head 02b6bd734789c42dbbddfe40de4e32ef762440ab.

The original 2345-line runtime mixes memory search, source reads, storage/event effects, write/retract argument validation and failure policy. Private keeper_tool_memory_validation owns canonical mutation input/error variants, validation precedence, basis receipt projection, corrective fields and typed failure class/effect descriptions (525 lines). The root keeps search ranking/logging, source/file reads, snapshot/receipt changes, event recording and cancellation handling (1828 lines).

fact_store is defined once in the pure owner. The root re-exports its constructors with a manifest type equation, then includes the validation signature using destructive type substitution to keep that same type without redefining it. The compiler checked this connection. Public keeper_tool_memory_runtime.mli is byte-identical. No wrapper module, new public test API, field or compatibility reader was introduced.

All extracted function/type bodies are exact parent blocks after moving the derivation_half comment with its declaration and normalizing the helper's final newline. The retained root body is exact after the declared block removals, canonical type re-export and signature include. Validation defaults/precedence and failure policy retain their existing semantics; this is not a claim that their entire policy has been independently re-proved. No performance improvement is claimed.

Focused build `opam exec -- dune build test/test_keeper_memory_write.exe test/test_keeper_memory_write_supersedes.exe` completed exit 0.
Selected command `_build/default/test/test_keeper_memory_write.exe test validation --color=never`: 7 PASS, run R0MSLEPC, exit 0. Other groups were skipped and are visible in the retained log.
Command `_build/default/test/test_keeper_memory_write_supersedes.exe --color=never`: 14 PASS, run 2SBRQN0T, exit 0.

The 21 distinct successful cases cover typed invalid write/retract arguments, corrective premise coordinates, Board reference combinations, body composition, known pre-effect rejection, atomic supersession, authored ownership, support invalidation, refusals without mutation, removal evidence and source-bound refusal. The fixtures use isolated temporary workspace/keeper files. Endpoint/sandbox/source-runtime groups were not run; no live Keeper or provider was contacted.

Source review, focused compilation and these selected executions are separate from full CI, installation, live runtime, formal GitHub approval and merge. Dune private_modules is source/build configuration, not an observed installation result. The baseline candidate remains partially improved with search, source/storage and event effects pending semantic audit. Falling below 2000 lines does not complete its original scope; the 171-candidate campaign remains open.
