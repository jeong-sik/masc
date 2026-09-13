# Local memory proposal semantic audit

Source-entailment and provenance audit of the actual 24-source local proposal plus saved operator-assisted reuse. Not promotion, approval, current runtime validation or independent verification of underlying remembered events.

Actual proposal: `9b676bb25ad23dc951bfd7b8e5130f9b58a0384b205c8e40123df0e2865f98ff` (`model_proposed`).

The requested qwen38-27b-stream files are a synthetic 4-source Dataset D/measurement N example (1 claim, 1 conflict). The actual 24-source, 10-claim, 2-conflict payload is memory-proposal.json and is exactly equal to memory-reuse-35be4/full-proposal-read.json result.proposal.

## Claim-by-claim source support

Supported means faithful attribution to the saved source, not established underlying truth.

| Item | Verdict | Source IDs | Finding |
| --- | --- | --- | --- |
| C01 | supported | s10, s11 | Event framing, audience, date/time, venue and no-invention constraint faithfully reproduce designer records; admission wording is explicitly withheld. |
| C02 | supported | s11 | snapshot1.metadata.change.removed contains the collaboration-role entry quoted by the proposal. The proposal explicitly says it is not reconfirmed. |
| C03 | supported | s1, s2, s13, s16 | Palette, fonts, reported poster success and historical package/renderer availability match the cited designer/editor records. |
| C04 | supported | s8, s22 | Task-002 GIF/WAV/MP3 scope, multimedia directory, actual decode requirement, fiction notice, theme and requested evidence match the records. |
| C05 | supported | s9 | The statement expressly attributes execution confirmation of ffprobe 5.1.9/libmp3lame to exhibit-designer and matches s9. |
| C06 | supported | s5 | The calm, friendly Korean guide tone is faithfully attributed to designer memory of editor preference. |
| C07 | supported | s4, s7, s14, s15 | Empty-stdin lesson, reading approved replay artifact bytes, and no-op Edit lesson match their historical records. The proposal does not repeat s14's unjustified always-empty generalization. |
| C08 | supported | s17, s19 | The false-positive forbidden-syllable warning and codepoint/Unicode-escape workarounds match editor records. |
| C09 | overstated | s18, s20, s21 | s18 says 정량 기준 3개인 파일 존재·3페이지·evidence 기록: THREE CRITERIA, including file existence. The proposal changes this to three files, three pages, and an evidence record, inventing an exact file count. |
| C10 | supported | s23 | The proposal faithfully states that editor recollects preparing evidence_quality.md and explicitly says its contents are unverified. |

## Conflict review

- K01 — uncertain (s3, s6, s12): There is a possible methodological tension, but a direct contradiction is not established: s3 describes executing PIL pixel analysis for limited rendering metrics; s6 prohibits substituting reading script text for image inspection and requires semantic transcription/cropping checks. These are different evidence operations and scopes. s6 is a later record by the same owner; neither source explicitly records a resolution. Keep the methods and criteria separate. Do not call PIL metrics a replacement for title/date/fee transcription. s12 is an older editor tool-contract recollection; reuse evidence says the later schema accepts a path, so the historical handle-only limitation is not a current universal prerequisite.
- K02 — overstated (s10, s11, s22, s24): Preserving unresolved/corrupted admission wording and not reviving s24 is appropriate. However, rendering the corrupted Korean as admission being water rather than materials invents a resolved semantic contrast: s10 literally contains 물료가 아니라 물, and 물료 does not support materials. s22 and s24 also repeat garbled strings, so their intended corrected term is not derivable from these source bytes. This is evidence corruption/uncertainty, not proof two owners disagree over the real fee. s11 is a librarian snapshot change (removed and added entries); s24 is explicitly snapshot2.source.kind=explicit_retract and must remain withdrawn. Neither removed wording nor the model's English gloss is a current fee fact. Later source-code/visual evidence can establish a fee independently but cannot retroactively repair the source strings.

## Reuse boundary

- Stored actual proposal equals full lookup payload structurally. Model receipt context SHA matches.
- Initial handoff and persisted revision132 record overclaim historical/current facts (including absence implying historical falsity); the first review also fails to correct the proposal criteria/file-count transformation. The initial handoff does not itself restate three files.
- Corrected handoff bytes=6586 and SHA256=12bd9264c83411313dbb1f4a6c7ed1a1c126da3076e67cb81e0358acf16bcec4 match peer-review receipt.
- Saved ledger records successful export/materialize/Read and lookup of same proposal. Designer Read ledger is truncated_to=4000 with result_bytes=6909; this audit cannot reconstruct its entire returned document from that ledger.
- Designer Board review c-728b11366f3f8eba5bd424bee5e37e14 contains explicit criteria/file correction, absence versus historical-falsity distinction, attributed design reuse and an actual next-session plan.
- Correction keeper_memory_write succeeded at revision133; writing a fact whose text says replaces the old record does not prove explicit retraction/removal of revision132. The saved note expressly says old memory retraction is not yet verified.
- The designer independently requested source bytes from editor (kmsg-290f18125241cc7094ae744f136c574a); saved Board review leaves that source check pending.
- Saved peer_review_written=true and next_editorial_plan_saved=true coexist with peer_review_all_claims_verified=false; these statuses are not a contradiction.
- Board plan/reads prove bounded operator-assisted consumption. They do not prove spontaneous adoption, autonomous recurring memory lane, execution of the planned next session, or corrected workspace truth promotion.
- The historical corrected handoff and Board review still discuss September12 live states; they must not be used as September13 current-state facts.

No runtime/model/tool mutation, memory promotion, approval or new external message was performed. The original sources and proposals remain unchanged.
