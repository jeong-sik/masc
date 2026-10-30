# Keeper decision tool counts

The isolated collaboration runtime at source `9cc33feff4917a1ae91804771a708d4a0e75e152` returned zero tool calls for all model rows. The raw ledger window contained 26 completed turn records and 128 separate tool execution observations. All 26 turn records omitted both `tool_call_count` and `tools_used`; the metrics reader therefore used zero and an empty list. The existing per-Keeper metrics snapshot already carries these fields, but this API reads decision records and costs instead.

The independent trace/turn/agent-core-ordinal join matched all 26 decisions with exactly one cost row. Input, output and both cache token totals matched the three API rows. The 128 execution observations are not claimed to equal completed-turn call counts: ongoing turns and retries have different event boundaries.

The saved response was stale and refreshing. Its stored snapshot completion time was reconstructed from `cache.generated_at - cache.age_s`; a first response in this investigation was 2,228 seconds old. The UI currently ignores that cache metadata. This change only restores fields at the decision writer; historical records and cache freshness presentation are not repaired.

Validation: source parsing and `git diff --check`; CI is required for the behavioral writer-to-metrics test. No replacement binary has run this fix yet.
