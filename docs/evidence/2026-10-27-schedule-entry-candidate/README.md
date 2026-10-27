# C3 Scheduled Job candidate source selection

This is a duplicate-source, proof-only candidate for the original two-job model scenario. **Do not merge or install it.** The product repair remains PR #46311. This candidate starts from frozen C2 and adds only the leader-selected four leaf commits; it does not update main or adopt the moved #46202 head.

- C2 base: `a3950a189b9cc5a7ce82cb725699455d79923f42`.
- Source leaf: `98532cc5dcae3267587148d6f1823a16458268dd`, parent `625479cbf059b16a471e0c1477bb8eaca783b5ee`.
- Product assembly: `13d235b38c756a9d4b446fa74232f18e8979b180`. The documentation/changelog preparation commits after that product assembly create a different final candidate SHA; a native producer must bind the actual final SHA separately.

[Leader selection](selection.json) preserves the explicit C2 + four-commit decision and its original-envelope identity. It is a derived text selection, not a copy of the entire MCP envelope; that envelope is not retained here. [Assembly result](assembly-result.json) records each original-to-candidate pick, its scope and limitations. No manual conflict-resolution edit was needed.

The independent [source/integration review](independent-integration-review.json) is PASS for the product assembly, with no remaining P0–P2. Its reviewer did not assemble the candidate. Of the 32 leaf change paths, 31 final file blobs equal the leaf. `keeper_unified_turn.ml` instead preserves the C2 body and adds only the four admission-preparation arguments. C2's `pending_at_intake` yield, source cohort distinction and scheduled checkpoint retention remain intact. The three other lifecycle files are byte-identical to C2. This is not whole-file equality between the leaf and candidate.

The historical Test 40424838832 on leaf614 failed: 54 PASS / 9 FAIL over 63 cases, including one passing new admission/Host case. The two causes were an obsolete whole-context expectation and a catalog fixture missing canonical `model_id`. The fourth selected commit repairs only those test fixtures; it does not relax product parsing or change the original user body. Requested follow-up Test 40426117052 is separate evidence and has no success claim in this frozen preparation record. Those CI logs are not copied into this three-artifact selection.

The selected next scope is one existing minimal native producer for a matching server/TUI pair, then the original GLM and DeepSeek A/B scenario with its real tool arguments, destination and boundaries preserved. A1, B-only work, B ACK, exact A readmission, separate A-turn A2 and all owned tool rows must be checked. The earlier DeepSeek FAIL and GLM canonical-result-read correction remain historical evidence. Selection and source approval do not prove execution, model compliance, visible overdue notification or the whole Scheduled Job feature.

The [copy list](selected-copies.json), [manifest](selection-time-manifest.json) and [location sidecar](current-locations.json) bind exactly three selected artifacts. Removing the declared original-repository prefix gives each manifest key. Unretained-envelope/input hashes in those artifacts identify prior inputs, not public retained-byte claims. No credentials, provider inputs/reasoning, binary archive or runtime result are included in this preparation bundle.
