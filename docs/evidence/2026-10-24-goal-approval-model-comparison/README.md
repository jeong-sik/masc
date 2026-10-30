# One frozen approval request, two installed models

This diagnostic replays the captured Gemma post-approval request000019, SHA256 `79c160e303e8cbead51cb69235f72d4dcc256dce25836267e3b9a370fd83b137`. Both arms keep the same messages, schemas, options and think=true, and add the same seed20261024. Only model selection differs. Model identities and their declared context capabilities are explicit; this is not weight attestation or a randomized population comparison.

Gemma again returns a public stale-awaiting answer without tools. Qwen3:8b emits `Read workspace/acceptance.json`. No returned tool is executed. Qwen's proposed Read is not actual reading, metric measurement, persisted work or G3 success.

A subsequent fresh actual Qwen Keeper uses source3badb881, the same initial owner request, private Docker workspace and on-demand activation. That actual workflow is a separate experiment. Its Task creation omitted Goal association; operator linking before approval is explicit controlled G3 fixture setup, not an autonomous G2 success.

The two result records preserve request/response hashes and public output/tool choice; raw thinking remains private. No success rate is inferred.
