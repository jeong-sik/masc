# TUI body and content activity ownership

Base: `c38df4e56c9b4be63c212a096526e46750d14402`.

The live Thinking adapter and durable journal projection discarded the reported content index.

Thinking now retains its reported index through both adapters (`Live.Thinking.content_index`, populated by the live decoder and the journal adapter; the decoder rejects thinking deltas without exactly one valid index). Response-identity admission (closed-piece tombstones, channel admission, owned body gating) is NOT ported: the response-identity event machinery does not exist on this base, so transcript body handling keeps its existing signal/buffer behavior and ignores the retained index. Indexed fixtures use explicit `content_index`; unindexed observations keep prior behavior.

Changed interface: `Live.Thinking.content_index` -> live decoder and journal adapter. Direct fixture constructors explicitly identify unavailable indices.

Verification: syntax-only `ocamlc -stop-after parsing` passed for changed OCaml files; `git diff --check` passed. Fixtures were adapted and source-read, not executed. No typecheck, local Dune build, CI, installed binary, live runtime or screenshot verification. Source inspection is not a measured TUI reproduction or a RED/GREEN test run.

Remaining: transcript admission on the retained index, Text piece indices, whole-response terminal admission and broader provider/runtime, queue, timeline and visible UI verification remain separate work (blocked on the response-identity stack). No merge or completion claim.
