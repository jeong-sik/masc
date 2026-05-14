# KAL K-1 Admission Mapping: Retired

This audit previously mapped `KeeperAdmissionLiveness.tla` to the MASC-side
RFC-0026 admission modules. That implementation has been retired.

Current boundary:

- MASC does not own provider/model admission, token buckets, or WFQ fallback.
- OAS/cascade owns provider/model selection and capacity behavior.
- MASC retains the keeper turn semaphore path and runtime-lane observability.

Historical references to the removed modules should not be used as current
implementation guidance.
