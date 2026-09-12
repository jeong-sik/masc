# Runtime attempt scopes

Read-only inspection of runtime source `2578d7fec3061b0a8a05301eb465ae0521ce5461`
and exhibit-editor's persisted execution receipts, runtime manifests, raw traces,
and saved composite response 126. No provider call or live mutation was made.

| Keeper turn | Actual candidates in raw run order | Selected runtime internal attempts | Lane attempts | Fallback |
| --- | --- | --- | --- | --- |
| 404 | Kimi authorization failure → GLM success | 1 | 2 | true |
| 405 | GLM success | 1 | 1 | false |
| 406 | GLM rate limit; Kimi deferred | 1 | 1 | false |
| 407 | Deferred Kimi authorization failure | 1 | 1 | false |
| 408 | Kimi authorization failure → GLM success | 1 | 2 | true |
| 409 | GLM success | 1 | 1 | false |

Response 126 projected turn 408, recorded at `2026-09-12T13:09:49Z`.
It retained `attempt_count=1`, `fallback_applied=true`, and
`outcome=passed_to_next_model`, but omitted the original `lane_attempt_count=2`.
The selected GLM raw trace reference starts at sequence 5; the same raw file's
sequences 1–4 contain the failed Kimi run. Thus the selected-run reference alone
is insufficient to establish the full candidate walk.

Turn 408 raw file SHA-256:
`276261082290a13fc96d23dfeb43f9fa2d7a3b8ed32a790ad22f129d31e174de`.
Routing run `605bea43b242fe63656bc648c9b1b1a1` records candidate index 0 as
`kimi_coding.kimi-for-coding` and index 1 as `glm-coding.glm-5.3`.
The complete allowlisted local audit is
`/tmp/masc-runtime-failover-2578/receipt.redacted.json` (not a portable artifact).

## Selection explanation and limits

`Runtime.with_terminal_default` appends the fleet default even to a declared
singleton lane. Therefore the configured GLM singleton plus fleet-default Kimi
materializes as GLM, Kimi. `Keeper_turn_driver.quota_ordered_runtime_ids` can
move a rate-limited candidate behind another candidate. The GLM rate limit in
406 and Kimi-only deferred attempt in 407 are recorded. On 408 the fresh walk
selected Kimi first; after GLM succeeded, 409 selected GLM first again.

The source explains that ordering via GLM candidate backpressure, cleared on
success. Its historic process-local state was not separately captured, so this
causal association is source-derived. Kimi's weekly-limit response was typed
`AuthorizationError`; this variant does not record quota/backpressure evidence.
No string-based reinterpretation or routing change is part of this fix.

The change preserves the producer's lane count in the composite API. The
feature fixture persists receipt JSON and reads the composite execution view
for two candidates, one candidate, and an absent observation. Parse-only checks
pass; native execution is delegated to exact-head CI. This is an API projection
change, with no dashboard rendering or deployed-binary validation claimed.
