# One frozen inference-only Goal carrier placement diagnostic

The actual Gemma Keeper run retained the current Goal but repeatedly omitted the required Task description. The exact schema and missing-description error were present on wire. This diagnostic freezes raw request000004, SHA256 feaece7293008a8c863dbb0a9e2b53a0b84ece128db9815bda42be6a11ecfedd, including that corrective tool result. No returned tool was executed.

All three arms use the same installed gemma4:e2b registry digest, original schema/history, temperature0.4, think=true and explicit seed20261024. This seed creates a new diagnostic cohort; the original live run had no pinned seed. Tail User leaves the existing Goal carrier in place. System suffix moves only its exact text to the existing leading system message. Leading User moves only the same carrier before the owner's first User message. Body hashes, schema fingerprints, roles and actual emitted arguments are retained. Raw provider Thinking is excluded.

| Placement | Description >=10chars in actual emitted Task-create args | Matching Goal ID |
| --- | --- | --- |
| Trailing User | absent | yes |
| Leading system suffix | present | yes |
| Leading User | present | yes |

This is one frozen correction example with one seed per arm. It supports investigating carrier position for this failure; it does not establish population success rates, a universal provider result or model-weight independence. The reported token counts are raw provider observations, not a controlled performance comparison. Field checks in the results are explicitly presence/type/length and matching-ID checks, not execution of the canonical Task handler.

The earlier native HTTP test proves Task persistence against a deterministic peer; this replay proves no Task creation or G3 continuation. The failed live run remains failed. Any placement implementation must preserve actual system/extra-context carrier provenance, checkpoint behavior and official-client parity before a fresh real Keeper experiment.
