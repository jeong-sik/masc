# Actual Goal continuation: work succeeded, completion reporting failed

Candidate: `54e8b9b7cafab6122b8eccc9e15d8ec549e03ad8`.
Model: local Qwen3:8b, digest
`500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`.

The fixed G3 contract remains **FAIL** and the campaign remains **10/11**.
Actual remaining work and a persisted 3/3 observation succeeded. The final
public response nevertheless called the Goal verified/achieved and predicted
that Task approval would complete it. The authoritative Goal remained
`executing`; verification and final human confirmation had not occurred.

## What actually ran

The server binary passed ZIP CRC, published SHA256 and embedded source checks.
Its SHA256 is `6a2266ee62065039dfd4f37651b21122f8a239041bd762532392f9f46b5f0b57`.
The [extraction receipt](server-extraction-receipt.json) describes the reused,
provenance-matched support libraries. This is an isolated server experiment,
not a full new package installation or production deployment.

Native run [40105703498](https://github.com/jeong-sik/masc/actions/runs/40105703498)
passed 27 Task-outcome cases and two tool TOML parity cases at this source.
macOS artifact run
[40105705308](https://github.com/jeong-sik/masc/actions/runs/40105705308) selected
this explicit candidate; its workflow head differs from the candidate source.

The initial owner request and Keeper instructions match the previous Qwen
cohort. The model received no Goal ID hint. In request 6 it created a Goal-linked
alpha Task, then claimed it in request 7. It recovered from actual path/edit
tool errors, changed only alpha, reread the file and submitted the first Task.
There was no execution reminder or operator-added Task association in this run.
G2 therefore passes for this measured candidate and cohort.

The controlled operator proxy inspected the immutable submission and matched
current bytes before approving Task 001 at **15:36:18 UTC**. Its partial artifact
was 46 bytes, SHA256
`5fa852df4c27a68cc7e0c127b94c0fe2169a33f55201d50b20618a9ba45e9f06`:
alpha true, beta/gamma false. The
[inspection](partial-inspection.json), [approval](approval-receipt.json) and
[retained artifact](partial-artifact.json) preserve that boundary. This operator
proxy is not an independent LLM verdict or human Goal confirmation.

## Approval to observed result

No Keeper message, synthetic reminder or additional approval followed the first
Task approval. Request 15 received the actual approved Task outcome. The model:

1. Created and claimed the Goal-linked beta Task, edited and reread the file,
   then submitted its immutable artifact.
2. Created and claimed the Goal-linked gamma Task, edited and reread the file,
   then submitted its immutable artifact.
3. Called `masc_goal_measure` in request 26 with the current criterion revision
   and actual final 3/3 observation, persisted at **15:39:12 UTC**.

The final file was 44 bytes, SHA256
`481126b0b86f1f7bb6b1c5a3fa4ac7ec3a394facfc6cb6af1aa1eba163c2aa71`.
The beta submission separately retained its earlier 2/3 snapshot. Task 001 was
Done; Tasks 002 and 003 remained AwaitingVerification. The event queue then
acknowledged the completed continuation turn. See the
[actual diagnosis](postapproval-diagnosis.json),
[persisted snapshot](postapproval-snapshot.json),
[public final response](final-public-response.json) and
[independent runtime audit](independent-runtime-audit.json).

The final response incorrectly summarized approved Task 001 as still awaiting,
described measurement as Goal verification and implied that Task approval would
complete the Goal. These statements do not match persisted state. The owner also
asked for an intermediate measurement before remaining work; the only actual
postapproval measurement occurred after the final edits. Neither miss is waived.

## Limits and next repair

The only postapproval Task listing explicitly requested
`status=awaiting_verification`; it correctly excluded Done Task 001. The model
did not issue an exact-ID query in this continuation. Native query results
establish the repaired lookup behavior, but this run does not isolate that
repair as the cause of improved work. Model inference was stochastic and the
parent Goal context fixes also changed between cohorts. This single run does
not establish a success rate.

The existing prompt and canonical tool description already distinguished a
reported observation from completion. The old receipt nevertheless named
`reported_only` under `verification` and omitted the actual Goal phase. The
[receipt repair](../2026-10-25-goal-measurement-receipt/README.md) exposes the
transaction's actual phase without advancing it. A fresh actual Keeper run is
required to judge its full G3 behavior; frozen inference alone does not pass G3.

Raw provider thinking and credentials are excluded. Paths and hashes identify
the preserved private originals; the selected public files support the stated
observations without requiring those private paths to be accessible.
