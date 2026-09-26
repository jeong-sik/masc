# Server comparison harness plumbing smoke

This is one local macOS smoke using an installed-file snapshot with embedded
source declaration `97ed4b9f508727944bdec361dd4d3e271d1a510a`, SHA-256
`732abb40ac65f8df793481bcf92260dd48fb1e0ebad1f1edef155946110df5fb`.
`artifact` and `run_id` are explicitly null: there is no CI source-input
attestation for this file. It is not the live server image, a Linux test,
the backlog-worker candidate, or a before/after performance comparison.

The new session runner completed 250 multilingual seed tasks and two cycles
per phase while requesting gzip. The independent driver validator accepted
ten measured requests: two each for mutation, cold execution GET, warm GET,
concurrent mutation and concurrent liveness. Both concurrent pairs overlap
at the client. The final 254-task primary/recovery copies are byte-identical,
with revision 18 from initial revision 1. The server exited zero and was
reaped; the model stub stopped after one discovery GET and no POST.

The cold execution replies were identity; the warm replies were gzip. The
current source's `Execution_json` fallback has `compress:false`, so accepting
gzip does not prove it was sent. The harness reports actual encoding counts
separately from the requested-encoding axis.

## Retained evidence

The directory contains identity, projected before/after health, all 26 HTTP
receipts, complete synthetic backlog copies, server log, cleanup, success and
validation output. Large text files use deterministic gzip. The reader can
recompute their decoded hashes using `redaction.json`; `files.json` covers
the stored files.

Owned-workspace and snapshot paths are normalized. Seven response bodies
contain such paths: their original `body_sha256` and `json_bytes` remain
unchanged, and separate `published_body_sha256` / `published_json_bytes`
describe the public text. All timings and wire sizes are original. Other
response bodies are unchanged. The strict validator ran against the original
private receipts, not these normalized bodies. Health is projected to the
four groups it consumes; this is explicit in the redaction record.

Earlier local attempts found a canonical temporary-path mismatch and the
incorrect assumption that every gzip-accepting request returns gzip. They
failed and cleaned up; no failed attempt contributes to this smoke. Resolving
the temporary path and recording accepted versus actual encoding fixed those
harness issues. The eleven synthetic validator tests, Python syntax parsing,
`actionlint`, and diff whitespace check pass. Linux workflow execution and a
full paired server measurement remain pending. The measured times here are
not an optimization result or evidence of the 0.1 ms goal.
