# RFC-0026: Retired MASC Admission Router

Status: retired.

The MASC-side provider/model admission router has been removed. Provider and
model choice now belongs to OAS/cascade; MASC keeps only neutral runtime-lane
observability plus the existing keeper turn semaphore path.

Retired implementation artifacts:

- `keeper_admission_glue`
- `keeper_admission_policy`
- `keeper_admission_registry`
- `keeper_admission_router`
- `keeper_admission_runtime`
- `keeper_provider_token_bucket`
- `keeper_wfq_overflow`
- `KeeperAdmissionLiveness.tla`

Do not add new MASC-side provider/model admission policy. New provider capacity,
fallback, or model-selection work should land in the OAS/cascade layer and expose
only redacted runtime-lane summaries to MASC dashboards.
