# Candidate-native retarget/cancel observation

On 2026-10-27 KST, an owned isolated server executed the earlier F1 retarget/cancel
scenario with candidate source `c52f799e52d3683bd2a4c624f0f6adfe36015ec9`.
The downloaded server SHA-256 was
`373ced2eb4897f60d82a0c4b4b7340865e933f0e181a268906ddc595c9034af7`;
both [the `masc build-commit` observation](build-commit-observation.json) and `/health?full=1` confirmed the source, and health
confirmed the digest and disposable effective base. The operating installation
was not changed. [Producer result](producer-result.json) records completed/success
**Minimal manual checks40374265429**, workflow execution head
`9377c7f3025d68e3856d2afd3762468dabc77813`, ref `main`, separate source input c52f799e.
[The original native receipt](native-receipt.json) identifies all artifact binaries.

The controller created two manual, create-only, paused Keepers using a dead
loopback provider fixture. It observed one original recurring wake pending at A,
including the exact post/ref/incarnation and successful original-instance wake
receipt. The same authenticated named admin retargeted the definition to B,
creating a new instance, then cancelled it. Both authoritative owner inventories
had no original source and no pending `schedule_due` work afterward.
[Finding](finding.json), [before](inventory-before.json),
[after](inventory-after.json) and [original request/wake](schedule-before.json)
retain this bounded positive observation. Final selected status confirms both
paused, zero turns and no last runtime attempt. The owned server stopped with
exit0 and no forced kill.

This is one A-to-B case. It does not prove concurrent transfer, all owners/races,
Keeper resume, model execution, external destination delivery, visible TUI,
production installation or the whole scheduled Job feature. The earlier actual
[failing installed-binary capture](../2026-10-26-schedule-runtime-behavior/README.md)
remains unchanged. Its failure and this candidate success use different binaries.

The ignored derivative controller is
`artifacts/schedule-actual-repair-20261027/probe_retarget_cancel_fixed.py`, SHA-256
`7e4647868f2da37aaabceb769c14f0ec1443ef41e19e5e9539ed6cedad6af3d1`.
It derives from the versioned original probe, SHA-256
`1e9dd3af05a6ff47fcf4a0d13ef75ca6a201a36e7696c794f4e9e3a0e174427a`;
its positive oracle and explicit candidate identity replace the original negative
oracle/installed-binary defaults. It reads the fixture from that exact candidate
source, creates a fresh owned base and writes a fresh run directory.
[Capture manifest](capture-retention.json) separates original retained bytes from
selected status/provenance derivatives; raw API/server/status captures remain ignored.

## Actual scheduled Lane export and ownership control

[Run2](lane-export-2/summary.json) used the same candidate-native server and the
unmodified source-bound operator-quiz package0.2.1, mounted into the already
present Docker image `masc-lane-operator-quiz:0.1.0`, immutable image ID
`sha256:69fbf57d7775244ed37ddf88b6d7d4da6329fd25748b8ff5bcf7011ce6ea2a0c`.
No image was pulled, built or substituted. The owned server used a fresh base,
real Docker worker and source-bound dead loopback model fixture. The declaration
selected no Exact Outputs or optional tool hooks; no model was invoked.

One HTTP Admin-created export became due. The canonical signal's occurrence,
original schedule instance, due and payload digest matched the handoff and
[confirmed original worker action receipt](lane-export-2/export-receipt.json).
A separately queried [actual namespaced measures lane](lane-export-2/export-evidence-response.json)
referenced the export digest. Host-retained raw bytes matched an independent
successful read-only copy from the exact owned worker's persistent volume.
The fresh log was **absent and exported as zero bytes**: empty SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
This proves the bounded empty-export pipeline, not journal mutation or quiz/model
behavior. Matching image/package protocol hashes do not attest all image source.

A separate far-future control schedule never dispatched. The authenticated
Worker's [cancel response](lane-export-2/worker-cancel-response.json) was
HTTP400/`not_schedule_owner`, named the Worker and original Admin, and left the
exact durable row unchanged. Admin then [cancelled successfully](lane-export-2/admin-cancel-response.json)
with a `human_operator` cancellation stamp. HTTP create also stamped both actor
fields as human operator. This is one actual credential-role/ownership case,
not full RBAC or a forced race.

The real owned worker was detached and its exact container absence confirmed;
the server exited0 without forced kill. The named owned persistent volume was
preserved. No operating server, installation or other worker was changed.

[Run1](lane-export-1/summary.json) failed a **controller oracle** after the worker
confirmed export: it queried local `quiz/measures` rather than the actual
`<instance>/quiz/measures`. The [complete empty response](lane-export-1/slice-response.json)
and [source-based diagnosis](lane-export-1/diagnosis.json) remain separate.
That first run did not execute the later byte or ownership comparisons. The v2
controller selects the actual inspected lane identity before querying it; no
assertion was weakened and no first-run captures were overwritten.

The three controller source captures (`*.py.txt`) preserve original bytes and
hashes as review material. To execute, place the chosen source under a checkout's
`artifacts/schedule-actual-repair-20261027/` (its repository-root derivation uses
that location), supply explicit verified identities and a fresh output directory.
Do not run these captured copies in place. These probes establish neither all
scheduled actions, external-effect exactly-once, power-loss/restart, busy model
checkpoint behavior, visible TUI, production installation nor full feature PASS.
