# Immutable tool and Skill activity projection

PR #42139. Base: 4b3c3769fa5b9e7883dfebdfe377c362b8ff1ab1. Reviewed code: 278b57fa8ab62dd13ed0a7ddd045273fd05623a6.

Private masc_tui_keeper_chat_activity_projection owns eight canonical immutable activity types, construction and tool/Skill row projection (866 lines). Root retains mutable stream buffers, live calls, attempts, delta application, reconciliation and drawn-trail state (2672 to 1882 lines). Manifest type re-exports and destructive type/module substitution preserve the public MLI byte-for-byte. No forwarding functions were added. Activity calculations use static descriptor lists and pure name/subject/count helpers; no filesystem, clock or runtime acquisition enters this owner.

Projection and constructor function bodies are unchanged. A four-line record-resolution comment about awaiting_approval was removed because that record now belongs to the other module. All other retained root logic is unchanged. Existence of a clear owner does not prove every classification, truncation or folding policy correct.

Initial focused build failed with duplicate module Projection after include. Destructive module substitution corrected it. `opam exec -- dune build test/test_tui_keeper_chat_transcript.exe` then completed exit 0 on the executable source committed as 31f32bd0601b9ac2709661033db1184633f69dae. `_build/default/test/test_tui_keeper_chat_transcript.exe --color=never`: 110 PASS, C8H30B3O, exit 0. Subsequent code commit changes only the displaced comment; no executable body changed and no repeat build was run for that comment.

Existing tests exercise in-process timeline/content/trail, tool outcomes and folding, terminal-safe returned text, approval holds, status and attempt transitions. Direct history and render consumers still use the existing transcript API. Seven current source hashes, one executable receipt and bounded output are retained. These are returned-data tests, not a physical terminal screen or live provider run.

Independent final review is pending. Formal GitHub approval, merge, full CI, installation and actual terminal behavior remain unverified. Stream/state, classification and rendering policy/performance audit remains pending; crossing below 2000 lines does not complete this candidate or the 171-file campaign.
