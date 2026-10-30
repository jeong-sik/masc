# Goal daemon progress and original-read diagnostics

This extends the first [completion feature evidence](goal-original-body-isolation-20261025.md)
after an adversarial review found that its passing worker/drain tests bypassed
daemon admission. Tracking: [#45975](https://github.com/jeong-sik/masc/issues/45975),
MASC task-2672. Native Stack #45953 adds baseline #45976, scheduler repair #45977
and current-request diagnostic/consumer repair #45986 above #45964.
The corrected baseline executed both failures; the candidate passed all 440
selected cases. The [machine-readable receipt](goal-daemon-progress-20261025.json)
pins completed run/job/source identities, input/log hashes and observed excerpts.

## Executed failure and repair scope

The actual daemon selects a bounded set of Goals for review. At baseline, four
higher-priority Goals with corrupt original bodies released their claims without
scheduling the healthy fifth Goal. A separate baseline case found no request-bound
Board notice for an original read that failed before the normal review path.

The repair retains observed, not-yet-admitted Goal identities in a queue alongside
active claims. Queue removal and reservation are one atomic state change; the
available batch is reserved before any fork. Every settlement releases capacity
to that queue. Only explicit Goal wakes and provider retry timers request fresh
discovery, so returning capacity does not automatically retry the failed prefix.
The queue preserves discovery order; newly discovered work appends. It is a
process-local observation, not a new durable authority or dispatch grant.

Original-read failures retain typed worker errors and their exact workspace,
Goal criterion and pending request. Each read owns its observation identity, so
late results cannot overwrite or erase a newer one. Planning uses the existing
bulk authoritative proof read and the existing `{step, detail}` shape with the
closed `Read_original` step. The Board uses its existing request-bound stall
protocol. Successful body reads clear only their own diagnostic before model
entry. Unavailable rebinding preserves the observed error; shutdown clears only
the closing workspace's captured observations.

## Native receipts

All checks use `test.yml`, `minimal=true`, and the existing
`scripts/ci-run-targeted-tests.sh`. No local Dune build was run.

| Role | Source | Run | Observed result |
|---|---|---|---|
| Initial baseline | `6307e600f3a0a6319eb7ea12c4ebc8f97fd8a11e` | [40202466750](https://github.com/jeong-sik/masc/actions/runs/40202466750) | Compilation stopped at `Unbound module Random_id`; no test execution. |
| Corrected baseline | `1aa3ad727dd009ebbe7fa21469e7dc256f36fdcd` | [40203843958](https://github.com/jeong-sik/masc/actions/runs/40203843958) | `test_goal_verification_agent`: 41 cases ran, 39 passed and exactly the two new daemon cases failed. |
| Repair candidate | `d6c6a4e9312bc77b276811e0289a3469725eccc9` | [40204323393](https://github.com/jeong-sik/masc/actions/runs/40204323393) | Goal agent 42/42, Goal worker 20/20, TUI decoder 378/378 passed: 440/440 selected cases. |

The baseline dependency correction adds `masc.masc_random_id` through the shared
test dependency library as its contributor instruction requires. Test source is
unchanged by that correction; all stack layers were restacked and pushed together.
The baseline suite reported 120.276 seconds, including its existing awaited-event
safety bounds. This is not a product latency measurement.
The candidate suite times were 103.088 seconds, 1.538 seconds and 0.019 seconds
respectively. These do not include build/setup and are not a throughput comparison.
Both behavioral runs are completed workflow-dispatch attempt 1 on the sources
above. Subsequent evidence-only commits do not imply another run at their heads.

Observed baseline failures:

```text
healthy fifth Goal never published after four damaged originals released daemon capacity
the daemon never published the original-body failure notice
2 failures! in 120.276s. 41 tests run.
```

Candidate selection:

```text
test_goal_verification_agent,test_goal_verifier_worker,test_tui_decode
```

Execution-input SHA-256:

| Input | Digest |
|---|---|
| Targeted runner | `7391426895132a2c027aea2d6c85bfcae18a038fd4e9640cc3c0b9fa66a8ca72` |
| Workflow | `6fb355583ed464aa653687f6882c72d936507654ff25fa6c67a795d02cf0d191` |
| Candidate Goal agent test | `2e31d7ceccf5437c749639beefa90e59f93a1843d5487a81e743e4d4ba7e99e4` |
| Candidate Goal worker test | `fd30be1fed532b28dd5eb8cacf52416ec57c034d803722ba40fafecdba1f530d` |
| Candidate TUI decoder test | `54e315a72f456bb4668acefc33f82186d0b6533c0ff46ce107985d2b8a30d931` |

## What the scenarios require

- Actual `Goal_verification_agent.start`, four priority-1 corrupt originals and
  a priority-2 healthy fifth, with no additional external wake. Healthy work must
  perform the real lookup and preserve proof request/run, terminal publication
  and both ACKs after worker join. Damaged bytes and pending requests stay intact.
- An early body failure must reach the actual Board with the Goal/request,
  `Proof_lookup_unavailable` and `No_retry_armed`, without reviewer entry.
  The duplicate-notice assertion observes the suite's existing 0.2-second idle
  window after another installed wake; it is not unbounded deduplication proof.
- Exact body restoration and an explicit retry keep the same request/run. The
  real planning payload passes through the TUI decoder and clears its diagnostic
  while the reviewer is held before its answer, then proof/publication completes.
- Copying actual Goal/proof state into another workspace cannot carry the first
  workspace's diagnostic. Reopening with the same criterion creates a fresh
  request, and changing the criterion also prevents stale diagnostic inheritance.

Independent source reviews inspected cancellation, in-flight wakes, provider
rest, reserve-before-fork and stale observation ownership. The new observation
finish races are source-reviewed; no separate new injected concurrency test for
every ordering is claimed. Current-head source verdicts and full diff identities
are in the corresponding PR descriptions, separate from native receipts.

## Remaining evidence boundaries

Reviewers are controlled hooks. These fixtures prove runtime/owner/consumer paths,
not an increase in real-model task completion. The TUI decoder consumes actual
server data; an installed display was not exercised. No full `@runtest`, release,
merge, installation or production-server restart is included.

Unclassifiable metadata remains an explicit global error. Historical requests
within a Goal keep their original publication obligations; they are not skipped
merely because a newer request exists. Phase-moved historical publication failures
are outside the pending-request diagnostic. These limits are not silently converted
to success by queue draining or current-state display.
