# Current submission owns its evidence

Base: `32805eb764eab2710262446e925b0ea5c3a44c08`.

The observed ordinary HTTP recovery sent identical arguments in requests 15 and
17. The transition constructed a claim from the new handoff but passed the old
Task to verification preparation. That projection merged the rejected Task's
handoff into the new claim. Rejection had put a bare verification ID in
`evidence_refs`, although that field contains evidence-reference wire values.
The first retry therefore inherited an invalid reference; the subsequent retry
saw the replaced handoff. This is a server dataflow defect.

The independent diagnosis is
`/tmp/masc-independent-2be9-diagnosis-20261025/diagnosis.json`, SHA256
`061803d6221750dccd05c0de3a9106e1fc68d20238647380f89888042ae10954`.
Its actual-source helper receipt has SHA256
`ea18954559edddc7c412834d684396f61e1d1597a9e8214c71b2e9e879d30bad`.
The missing intermediate request's original artifact body remains unknown.
Its absence agrees with the supersede-delete source path; no unlink syscall was
observed. This repair does not establish an artifact filesystem read failure or
turn the failed model run into a successful Goal experiment.

The executor now returns the same immutable transitioned Task that it installs
in the backlog. Capture, claim construction and notification use that value.
The verification projection accepts the current claim as the sole submitted
evidence authority; contract requirements remain separate. Rejection and
unroutable-release producers retain verification correlation in existing typed
records, events and activity fields, and no longer put that ID in evidence refs.
No reference is suppressed based on its spelling: an explicitly submitted
malformed reference still produces a typed diagnostic.

Operator cancellation preserves the owner's handoff as before. Its
`persisted_handoff_context` still describes what the operator transition
authored, rather than the inherited owner handoff. Note-only Task submission
policy, supersede deletion, compensation and verdict authority are unchanged.

| Contract | Direct consumer | Verification |
| --- | --- | --- |
| Executor returns committed Task | Task transition prepare and notification | Actual executor interface/implementation probe; authored native consumer fixture |
| Current Task owns handoff refs | Workspace submission claim helper | Actual helper interface/implementation probe, including absent handoff |
| Claim owns submitted evidence | Verification protocol and completion review | Actual request-spec constructor and review module; baseline contamination reproduced |
| Correlation is not evidence | Rejected verdict and unroutable release | Existing verdict/release fixtures extended; typed outbox ID retained |
| Exact retry preserves capture and actor provenance | Actual Workspace transaction and verification store | New native `test_verification` fixture, authored and not locally executed |

Run `python3 docs/evidence/2026-10-25-submission-evidence-snapshot/probe_submission.py`
for the source-linked before/after check. `source-check.json` records each actual
module/interface or named port, its digest, compiler command, and execution
output. It compiles the actual pure executor, claim helper, completion review,
request-spec constructor, snapshot codecs, reference grammar and full receipt
function. The minimal Task/configuration DTOs, fixture acquisition and request
loading are explicit ports. A small adapter supplies the old/new ordering;
it does not execute the full transition transaction, lock, sandbox acquisition,
HTTP transport, native response identity capture or a model.

The recorded execution passed 14 baseline checks and 19 candidate checks. The
baseline result includes reproduction of the bad first capture; it is not a
claim that baseline behavior was correct. Both compile outputs retain warning
23 from the minimal backlog DTO port, which has only the consumed `tasks` field.
`parse-check.json` records parsing of all 16 changed OCaml files, the probe's
Python AST and `git diff --check`, all passing. Parsing is not full typechecking.
`source-manifest.json` binds the changed source/test bytes and these check
receipts without including private model reasoning.

The new native fixture uses the actual Workspace submit → reject → change file
→ first retry sequence with identical handoff/claim arguments. It checks a fresh
request, no diagnostics, corrected retained content, immutable original content,
the submitting response's actor/model/tool identity, the shared notification
snapshot, refusal of a stale verdict, and an independent Task without a Goal.
The existing release fixture also checks that correction text remains while
its evidence refs contain no verification correlation ID.

Minimum hosted native targets are `test/test_verification.exe`,
`test/test_completion_repair_delivery.exe`,
`test/test_workspace_handoff_boundary.exe`, and
`test/test_workspace_task_verification_phase_e.exe`. The existing operator
cancellation coverage is in `test/test_workspace.exe`. No local Dune build,
native suite, CI run, publication or real retry on this candidate is claimed.
