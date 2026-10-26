# Completion feature delivery audit

This audits the requested research-to-feature plan, MASC work records, GitHub
issues and first Native Stack. The operator selected one demonstrated failure
through repair, reverification and delivery for the first implementation, while
recording all four improvement strands. It does not declare the wider Reliable
Change G1–G5 programme or MASC's real-model completion-rate improvement complete.

The original attachment, `pasted-text-1.txt`, and the local research report
`reports/MASC 작업 완료 능력 개선.md` were reread on 2026-10-26. The published
[feature plan](../roadmaps/completion-feature-execution-20261025.md) carries their
research hypotheses into concrete behavior, existing owners, acceptance and work.
Attachment SHA-256: `4b219e97e0b2df206b2d12cfae39316d01e9d6e709f300757237b0eb0a4ab619`.

## Requirement-by-requirement evidence

| Requested result | Authoritative evidence inspected | Assessment |
|---|---|---|
| Connect research to actual features | The plan's four-strand table specifies user-visible behavior, production boundaries, existing work and acceptance. Primary sources below were reread. | Delivered as an implementation and evaluation plan; research effect sizes are not MASC results. |
| Preserve rejection/correction/delivery work | task-2663; issue #45747 and existing Native Stack #45750. The plan requires original request, failed criteria, artifact revision, producer consumption, fresh verification and delivery to join. | Registered; current Task status is Done under its own owner. This audit does not independently repeat that campaign. |
| Preserve interrupted external effects | Existing task-2184; issues #41640/#45927 and the original G2 six-case crash/readback contract. | Registered, Todo. Durable execution context does not prove destination readback or exactly-once effects. |
| Preserve tool/observation experiments | task-2664; issue #45747 and existing repairs #45853/#45781. The plan fixes model/task/environment cohorts and measures accepted, delivered requests. | Registered, Todo; no completion uplift inferred from interface or latency changes. |
| Preserve cooperation/fault isolation | task-2666 and issue #45946; task-2672 and issue #45975 add actual-daemon admission and current-request diagnostics. | Both Tasks read back Done; controlled baseline failures and passing repair receipts are published. |
| Preserve outcome measurement | task-2665 and issue #44317; original-request denominator, actual producer identities, independent repeated trials, false completion, rework, duplicate effects, rescue and unknown outcomes are specified. | Registered, InProgress under another owner. This stack does not fabricate lineage or claim this work complete. |
| Repair and reverify the selected first failure | [Original-body evidence](goal-original-body-isolation-20261025.md) and [daemon evidence](goal-daemon-progress-20261025.md), source tests and recorded native jobs. | Healthy proof and terminal publication/ACK are observed while damaged bytes remain unchanged. Goal proof still awaits required human confirmation. |
| Deliver a real Stacked PR | REST Native Stack #45953 and seven open, ready PRs, with direct-parent ancestry checked after the repair below. | Published; merge, installation and production rollout are separate. |

Task statuses above were read from the configured live MASC workspace on
2026-10-26; they describe work records, not new execution of those features.
Plan task-2662 is also Done. Task-2696 tracks the stack reconciliation and this
delivery audit separately from already accepted work.

## Research to process

- [MAST](https://arxiv.org/html/2503.13657v3) supplies failure categories and
  intervention analysis. Here that becomes a specific observed failure, an
  implementation hypothesis and a negative/positive comparison.
- [SWE-agent](https://arxiv.org/html/2405.15793v3) supports holding the model fixed
  when comparing tool interfaces. Its coding-task results do not predict MASC's
  gain; task-2664 retains matched outcome measurement.
- [Scaling Agent Systems](https://arxiv.org/html/2512.08296v3) makes task structure
  a variable in collaboration experiments. The first feature isolates independent
  Goal work while preserving shared authority; no empirical threshold is copied
  into a runtime cap.
- [Long-running application harnesses](https://www.anthropic.com/research/harness-design-long-running-apps)
  motivates feedback specific enough to act on. [Managed Agents](https://www.anthropic.com/research/managed-agents)
  distinguishes durable session evidence from disposable execution context. The
  corresponding Tasks retain acceptance feedback and destination readback as
  distinct implementation requirements.
- [Tau-bench](https://arxiv.org/html/2406.12045v1) motivates external-state checks
  and independent repeated trials. Task counts, model turns, accepted wakes and
  one passing controlled fixture are not its reliability measure.

## Stack reconciliation

The resumed audit found that PR #45963 had advanced from `9a8b07f7887ecde3e6a44c1e13c89417b520ac94`
to independently reviewed `3a65b0756ab418649f9b942f1220737f6ed92dd0`, while the
upper PRs still lacked that amendment. The change keeps an unreadable Goal in
retained recovery discovery instead of dropping it from that scan.

The same local PR branch was fast-forwarded to the remote amendment; `gh stack
rebase --no-trunk` then propagated it through every upper layer. All seven
branches were pushed together. No remote amendment was overwritten and main was
not merged into a stack branch.

At the top layer, the new predicate required an explicit `pending_work` type:
the diagnostic layer also defines `original_read_binding.goal_id`. The type
annotation preserves the intended queue element. An inaccurate comment claiming
that every discarded per-row outcome is durable in the ledger was removed.

Current candidate source is `3f16ed48bba5a85337c57633ea4c363ba3fbb5e5`. Its delta
from previously published `94621a7840a1f53ea3f9904e95d4bbfb2a4c74c4` is one runtime
file, five added and two removed lines; original fixtures and runner inputs are
unchanged. The old 440-case result remains attributed to its original tested
source `d6c6a4e9312bc77b276811e0289a3469725eccc9`, not this candidate.

| PR | Role | Reconciled source head |
|---|---|---|
| #45951 | Four-strand feature plan | `2b4c002379c210393cd0b71b1725231689eea216` |
| #45952 | First negative reproduction | `774141773f76244ba7ce7adb677960d839ad5f8e` |
| #45963 | Original-body isolation and recovery discovery | `3a65b0756ab418649f9b942f1220737f6ed92dd0` |
| #45964 | Fresh-process recovery and evidence | `79b317e67f6147ccfce20a6175d70f5cb0e5b791` |
| #45976 | Actual-daemon negative reproduction | `c2d6dfaa57371e886001f1f863550acd94bbaa02` |
| #45977 | Healthy queued work makes progress | `315aea3325156d51a1151ccf32a46ab481ca0310` |
| #45986 | Current-request diagnostics and integrated candidate | `3f16ed48bba5a85337c57633ea4c363ba3fbb5e5` |

Evidence-only commits after the candidate are identified in the PR description;
they do not relabel native execution or carry a formal GitHub approval forward.
Current source/evidence review and complete diff identities are recorded there.

## Current focused verification

Workflow **Test** (`.github/workflows/test.yml`), run
[40282764729](https://github.com/jeong-sik/masc/actions/runs/40282764729), dispatched
at `fix/goal-original-failure-diagnostics-20261025` source
`3f16ed48bba5a85337c57633ea4c363ba3fbb5e5`, selects
`test_goal_verification_agent,test_goal_verifier_worker`, `minimal=true`.
Attempt 1 completed with conclusion **success**: **42/42 Goal agent and 20/20
Goal worker cases passed**, 62 total. Job `121439494566` reports suite execution
times of 105.498 seconds and 2.178 seconds; these are not product latency or
throughput comparisons. The [machine receipt](completion-feature-delivery-20261026.json)
pins the source, workflow/ref, runner and fixture inputs, saved decoded-log hash,
exact excerpts and independent source review scope.

The selection follows the changed agent interface through daemon admission and
the actual original owner/host consumer; the TUI decoder source did not change.
No local Dune build or full regression is part of this audit. The earlier
440-case run remains historical execution at its stated source.

The existing suites do not inject damage into a phase-moved Goal's own body.
That new discovery branch is source-reviewed. It leaves the Goal available for
a later explicit wake/boot; it neither arms automatic retries nor publishes a
durable Board/current-request diagnostic for historical publication failures.
The existing pending-request diagnostic boundary is preserved. Unknown generic
metadata remains an explicit global error.
