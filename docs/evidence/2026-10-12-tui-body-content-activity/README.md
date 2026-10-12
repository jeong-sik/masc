# TUI body and content activity ownership

Base: `44ebdae930d4c4192145ff9fef586bfb37017cd2`.

The live Thinking adapter and durable journal projection discarded the reported content index. Transcript body handling independently assigned Reasoning/Answering, overriding content metadata even after a piece ended.

Thinking now retains its reported index through both adapters. Indexed Thinking uses the existing response/content state machine, including closed-piece tombstones and channel admission. A distinct observed Thinking index can open a new piece; a late delta for the closed index retains its exposed bytes without reopening activity. Text and unindexed body observations preserve same-response content metadata rather than inventing a piece transition.

Changed interface: `Live.Thinking.content_index` -> live decoder and journal adapter -> transcript activity admission. Direct fixture constructors explicitly identify unavailable indices. Added state fixtures cover closed Text/Thinking, byte retention, new Thinking piece, and a new response reusing an index. Added protocol fixture covers retained indices and missing, duplicate, negative, fractional and unsafe indices.

Verification: syntax-only `ocamlc -stop-after parsing` passed for all 11 changed OCaml files; `git diff --check` passed. Fixtures were added and source-read, not executed. No typecheck, local Dune build, CI, installed binary, live runtime or screenshot verification. Source inspection is not a measured TUI reproduction or a RED/GREEN test run.

Remaining: Text does not carry a piece index; missing metadata cannot identify its occurrence. Whole-response terminal admission and broader provider/runtime, queue, timeline and visible UI verification remain separate work. No merge or completion claim.
