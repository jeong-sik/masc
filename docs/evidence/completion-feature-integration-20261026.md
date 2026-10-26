# Completion feature integration re-audit

The original request connects research to concrete features, an execution plan,
MASC Tasks, GitHub issues and a Native Stack. The operator selected one
demonstrated failure through repair, reverification and delivery for the first
implementation; all four research strands retain their own acceptance work.
This audit does not redefine that selection as implementation of every strand,
or claim a product-wide increase in real-model completion rate.

The original attachment was reread and still has SHA-256
`4b219e97e0b2df206b2d12cfae39316d01e9d6e709f300757237b0eb0a4ab619`.
The [feature plan](../roadmaps/completion-feature-execution-20261025.md) remains
the implementation map. Its earlier work-state snapshots are historical.

## Research, feature and work-record audit

| Requirement | Inspected evidence | Current scope |
| --- | --- | --- |
| Turn research into feature hypotheses and acceptance | Four-strand plan; primary sources reread below | Published, without importing research effect sizes as MASC results |
| Rejection, correction, fresh verification and delivery | task-2663; #45747 and existing implementation stack #45750 | Registered; Task is Done under its separate owner, without recertifying that campaign here |
| Resume interrupted external effects | task-2184; #41640 and recipient-readback issue #45927 | Task remains Todo; #45927 is closed, but does not prove the full G2 two-stage workflow |
| Compare tool/observation repairs by original-request outcomes | task-2664; #45747, #45853 and #45781 | Registered, Todo; matched model/task/environment comparison remains required |
| Isolate independent Goal work and finish retained publication | task-2666 / #45946; task-2672 / #45975 | Both Tasks have verifier-approved Done events; production-path controlled failure/repair evidence is retained |
| Preserve actual outcome identities and the original-request denominator | task-2665 / #44317 | InProgress under sangsu; synthetic identities and Task counts are not acceptance evidence |
| Publish the selected first feature as a Native Stack | Stack #45953: #45951, #45952, #45963, #45964, #45976, #45977, #45986 | All seven are merged; see the integration boundary below |
| Reconcile and verify integrated source | task-2696 and new task-2704 / #46089 / #46096 | The earlier Task remains AwaitingVerification; the newly found integration defect is repaired and reverified in the follow-up PR with its own execution evidence |

Task and issue states above were read from the live MASC workspace and GitHub
on 2026-10-26. Plan task-2662 is also Done. Task approval, branch test execution,
merge and installed-runtime behavior remain distinct observations.

The research-to-process mapping was checked against these primary sources:

- [MAST](https://arxiv.org/html/2503.13657v3) describes failure categories and
  intervention case studies. Here it motivates an observed failure, a bounded
  repair hypothesis and a negative/positive comparison.
- [SWE-agent](https://arxiv.org/html/2405.15793v3) compares interface designs
  using the same model. Its coding-benchmark gain is not a predicted MASC gain.
- [Scaling Agent Systems](https://arxiv.org/html/2512.08296v3) makes task
  structure a variable in coordination experiments. Independent failure
  isolation is the MASC application hypothesis; empirical thresholds are not
  runtime caps.
- [Long-running application harnesses](https://www.anthropic.com/research/harness-design-long-running-apps)
  motivates concrete evaluator feedback. [Managed Agents](https://www.anthropic.com/research/managed-agents)
  separates durable session evidence from execution context; it does not prove
  exactly-once external effects.
- [Tau-bench](https://arxiv.org/html/2406.12045v1) motivates final-state acceptance
  and repeated-trial reliability. One controlled passing run is not a repeated
  real-model success-rate comparison.

## Selected feature and merged-source boundary

The original [body-isolation evidence](goal-original-body-isolation-20261025.md)
and [daemon evidence](goal-daemon-progress-20261025.md) retain their exact source
identities. They demonstrate healthy Goal proof and terminal publication/ACK
while foreign damaged bytes remain unchanged, fresh-process retained judgment
recovery without another reviewer call, healthy fifth-Goal progress through the
actual daemon, and current-request failure diagnostics followed by recovery.
Required final human confirmation remains separate from proof publication.

REST readback confirms all seven original stack members merged between
`2026-10-26T07:35:15Z` and `2026-10-26T07:35:22Z`. Top merge commit
`02438c016a98419686e31d84beb83265d2cda685` is an ancestor of the inspected main.
This supersedes earlier open/unmerged snapshots without changing the source
identity of their execution receipts.

The re-audit found a real integration gap: the merged
`Anti_rationalization.reviewer_reply` requires `evaluator_execution`, but the
new controlled daemon fixture omitted it. The previous branch's 62 passing
checks therefore did not prove the integrated test target still compiled.

Baseline workflow **Test**, [run 40298386159](https://github.com/jeong-sik/masc/actions/runs/40298386159),
`main@8e2abe4fa6684462abbea32758e936075c63de9f`, attempt 1, completed with
**failure before selected suite execution**. Its actual compiler message is:

```text
File "test/test_goal_verification_agent.ml", line 1703, characters 9-85:
Error: Some record fields are undefined: evaluator_execution
```

[PR #46096](https://github.com/jeong-sik/masc/pull/46096) supplies `None` for this
scripted reviewer, which has no actual provider execution identity. It preserves
all assertions, production behavior, the record contract and the test runner.
The other reviewer-result constructors were checked for the same omission.

Candidate workflow **Test**, [run 40299208576](https://github.com/jeong-sik/masc/actions/runs/40299208576),
source `604a099602d1a7ca50fb468211a9d1e6641cf3e6`, ref
`fix/goal-evaluator-execution-fixture-20261026`, was requested with the same
selection: `test_goal_verification_agent,test_goal_verifier_worker`,
`minimal=true`. Attempt 1 completed with **success**: **42 Goal agent and 21
Goal worker cases passed**, 63 total. Completed job `121492669699` and workflow
metadata were read; both selected targets compiled and executed. The source
base and suite selections match the compilation-failing baseline. This new
63-case result is not the historical 62-case branch execution.

Native Stack **#46102** delivers code [#46096](https://github.com/jeong-sik/masc/pull/46096)
and evidence [#46101](https://github.com/jeong-sik/masc/pull/46101), linked to
issue #46089 and task-2704. The evidence layer changes only documentation and adds its own changelog; the
runtime, fixture and runner inputs remain those of the executed candidate. No
new execution on the documentation commit is claimed.

Independent source review covers the complete two-file code/changelog diff at
that candidate and found no P0–P2. This is separate from native execution and
formal GitHub approval. The [machine receipt](completion-feature-integration-20261026.json)
binds the execution and selected source inputs to their own identities.

## Remaining evidence limits

The missing-root/orphan and phase-moved own-body guards retain their stated
source-review scope; no new fault-injection execution is claimed for them.
Controlled reviewers do not establish real-model completion uplift, and the
fresh-process fixture is not a production server kill. Full regression,
installed UI, production restart and deployment are not established here.
The remaining follow-up Tasks retain their full acceptance contracts and owners.
