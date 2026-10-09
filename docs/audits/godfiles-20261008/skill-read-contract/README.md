# Typed Skill read contract and consumed metadata

PR #42148. Base: aa503fd160f2c2ba5f3405756412bd5120c33c3a. Code head: 60ee82980a21cc6038ae70dea48461fe9add02cc.

Client loaded Skill data no longer contains sel_snapshot_revision: global source search found only declarations and decoder construction, no read consumer. The server's snapshot field and the save receipt snapshot shown in the TUI remain meaningful and unchanged. Loaded exact reference, source text and access remain the consumed contract. HTTP root changes from 3430 to 3429 lines; main TUI remains 28921 lines at this parent (the older campaign count had drifted).

sel_access now uses the existing Skill_source_config.access closed type. Only the server wire forms read_only/read_write map to its Read_only/Read_write cases. Unknown and malformed access returns Error rather than being silently reported by the TUI as a read-only source. The main editor dispatcher explicitly matches both typed cases; the server still owns permission checks and write admission.

The effect-free editor wire owner is a private build library with an explicit MLI (119 ML/30 MLI lines), shared by TUI and protocol fixtures. It has no public_name and is not an installed public library. Four canonical types keep manifest re-exports at Masc_tui_http; no duplicate permission type or wrapper function is introduced. Other runtime-config and Skill-save codecs retain their bodies and interfaces.

Initial focused build found missing direct masc.skill_config dependency in the TUI; adding it corrected the build. Focused HTTP/main TUI bytecode objects and test_server_skill_editor executable then built with exit 0. Selected editor cases 0,6,33: 3 PASS, 24PQ33AS, exit 0; other 31 cases SKIP. Existing isolated real-file fixtures load and serialize through Server_skill_editor.loaded_to_yojson, then call the exact client decoder. They exercise known read-write/read-only access, missing unused snapshot metadata, unknown/non-string access and invalid exact reference. Existing save/publication and read-only write refusal remain exercised in cases 0/6. This is in-process protocol/file evidence, not an actual HTTP request or terminal editor interaction.

Eleven source hashes, one native library object hash, two TUI bytecode object hashes, one test executable receipt and actual output are retained. The hashes identify different build layers; no linked or installed TUI binary is claimed. Full CI, live provider, actual HTTP round trip, physical terminal, installation, formal GitHub approval and merge remain unverified. Final evidence-delta review is pending.

The campaign remains 171 candidates, with 46 production candidates partially improved and 29 awaiting semantic review. This resolves the two identified read-client follow-ups; remaining HTTP, TUI and editor response/authority policies require continued audit.
