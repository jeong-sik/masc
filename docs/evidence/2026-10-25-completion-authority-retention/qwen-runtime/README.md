# Actual Qwen cohort at 2be9d216

This is an ordinary HTTP Keeper experiment at source `2be9d21697fb4c9da9aafd769f5fa691bae2e757`, not the later Official Start repair at `32805eb764eab2710262446e925b0ea5c3a44c08`.

- [Initial owner turn](preapproval/diagnosis.json): unforced matching Goal association **PASS**; requested alpha-only execution **FAIL** because the model made all three fields true before approval.
- [Actual rejection and recovery](recovery/diagnosis.json): the rejection observation remains in the leading System across requests 10–19. The model restores alpha-only bytes and resubmits, but the first resubmission has capture diagnostics. The second structurally identical submission succeeds. Its stale final public report remains a failure.
- [First positive approval](postapproval/diagnosis.json): after strict current/immutable artifact equality inspection, the approved outcome reaches fresh request20. The model calls no tools and wrongly reports that verification is pending. **G3 FAIL**: no Goal measurement or remaining beta/gamma work. Postapproval tool-round retention is unexercised.
- [Independent diagnosis](independent-diagnosis/diagnosis.json): a Task transition feeds old handoff evidence into the new snapshot; a bare previous verification ID contributes `invalid_reference` on the first identical resubmission. The superseded intermediate record is absent, so its artifact contents remain unknown. Fresh approval delivery is verified; no sole explanation for the model response is established.

Operator verdicts are controlled canary fixtures, not independent LLM verdicts or human Goal completion confirmation. No extra Keeper message follows the positive approval. Provider terminal response, durable source acknowledgment and final observation times remain distinct in each report. Earlier source/native/runtime scopes and all failed intermediate states remain preserved. `publication-manifest.json` binds the copies.
