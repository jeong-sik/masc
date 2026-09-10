# Production verifier image delivery probe

## Baseline: aggregate submission rejection

A fresh isolated server at commit `1ef7ce2ec709b8b719e9687e774ea5258d87dee8`
received an actual Keeper message. Its configured synthetic producer emitted
`keeper_task_claim` then `keeper_task_done` with three valid PNG artifact refs,
497844 bytes total. The real tool returned `workflow_rejection`: aggregate
497844 bytes exceeds 51200 bytes, advising note conversion. The Keeper operation
finished Succeeded, but the primary Task remained in_progress; the verifier
provider received no request. Succeeded here means the chat operation ended,
not successful evidence submission.

The binary's three manifest hashes were checked before launch. It is an
unvalidated CI runtime probe build, not a release certification. The server was
stopped after the authoritative terminal Keeper operation and confirmed rejected
submission. Port 18937 and its data were untouched; the isolated port was 18945.

The baseline ran the first harness revision, before later uncertainty-cleanup
hardening. Its observed success path reached authoritative termination; no
uncertain cleanup path was exercised. The current harness additionally preserves
its server/provider on uncertain admission or read failure and waits for an exact
committed verifier verdict on the positive path.

Files under `baseline/` preserve real provider requests (including exact tool
input/result), primary backlog, operation readback, binary receipt, health and
server log. They contain only controlled fixture data. `sha256.json` binds the
stored bytes. Synthetic provider responses are transport fixtures and do not
establish document readability or semantic model approval.

## Repaired production reviewer route

Pending the repaired candidate and isolated run. No positive delivery or visual
verification claim is made yet.
