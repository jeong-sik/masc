# Goal original-body isolation: controlled feature evidence

This records the first feature selected in the
[completion feature plan](../roadmaps/completion-feature-execution-20261025.md).
Tracking: [#45943](https://github.com/jeong-sik/masc/issues/45943),
[#45946](https://github.com/jeong-sik/masc/issues/45946), MASC task-2666.
Native Stack #45953 contains plan #45951, baseline #45952, runtime repair #45963
and this recovery/evidence layer #45964. No merge or installation is claimed.
The selected native check reproduced two failures on the baseline and passed all
20 cases on the candidate, including fresh-process recovery. The machine-readable
[receipt](goal-original-body-isolation-20261025.json) pins run/job/source identities,
input and decoded-log hashes, and observed log excerpts.

## Failure and intended behavior

Retain independent Goal originals A and B through the existing owners. Damage
only A's body while keeping its valid metadata. The baseline reads all bodies
before selecting B, so A's failure prevents B's pending verification and retained
publication. The repair classifies strict canonical metadata first and restores
only the selected Goal's bodies. Boot discovery retains each Goal's body result
independently. The global complete census remains strict.

The positive scenario requires B's actual proof store, Goal phase, run registry
and original observer ACKs to agree. A's bytes must stay damaged and unchanged;
A's own processing remains refused. The expected B phase is
`Awaiting_confirmation`, not human-confirmed `Completed`.

## Native execution receipts

Both functional candidates use `.github/workflows/test.yml` with
`suite=test_goal_verifier_worker`, `minimal=true`, and the existing
`scripts/ci-run-targeted-tests.sh` runner. No local Dune build was performed.

| Observation | Exact source | Run | Result at this record |
|---|---|---|---|
| Initial baseline | `29d37febd5bb3a9dd479b23369a77ad54079189d` | [40195942798](https://github.com/jeong-sik/masc/actions/runs/40195942798) | Failed before the suite; existing TUI warning 4 was a compilation error. No Goal behavior observed. |
| Rebased baseline | `774141773f76244ba7ce7adb677960d839ad5f8e` | [40197032656](https://github.com/jeong-sik/masc/actions/runs/40197032656) | 19 cases executed: 17 passed, 2 failed in the selected foreign-body scenarios. |
| Runtime repair plus fresh-process probe | `a5bf5c2ebe3850b928ad90f53f190b9da98ea8a0` | [40197222178](https://github.com/jeong-sik/masc/actions/runs/40197222178) | 20/20 passed, including the added fresh executable and own-body refusal. |

The baseline pending-work failure was `healthy Goal blocked by foreign body:
Add-on request ownership unavailable: original request body does not match its
record's digest`. The baseline boot failure was `healthy Goal terminal publication
is absent`. The repaired cases passed on the candidate. Both runs are completed
workflow-dispatch attempt 1 on the source commits above, not queued receipts.

The native suite reported 1.552 seconds for the failing baseline and 2.002 seconds
for the passing candidate. These are test execution times, not build duration or
a product-performance comparison; the candidate includes one extra process case.

The whole stack was rebased onto
`f5c5fb447e60b79172d4a8ae411f391e3774f561`, which contains the already merged
TUI repair [#45938](https://github.com/jeong-sik/masc/pull/45938). The relevant
Goal/Owner production files and baseline test did not change across that base
move. This stack does not duplicate the TUI repair.

Execution-input SHA-256:

| Input | Digest |
|---|---|
| `scripts/ci-run-targeted-tests.sh` | `7391426895132a2c027aea2d6c85bfcae18a038fd4e9640cc3c0b9fa66a8ca72` |
| `.github/workflows/test.yml` | `6fb355583ed464aa653687f6882c72d936507654ff25fa6c67a795d02cf0d191` |
| Candidate `test/test_goal_verifier_worker.ml` | `fd30be1fed532b28dd5eb8cacf52416ec57c034d803722ba40fafecdba1f530d` |

The same passing suite covers original destination/authority refusal, strict
global inventory, linked frontier recovery, unknown-outcome/cancellation fences,
phase-moved boot recovery and cloned-workspace refusal. The unchanged missing-root
and orphan-successor guards and new canonical metadata selector were independently
source-reviewed; this receipt does not claim separate new fault-injection cases
for every malformed metadata or lineage combination.

Full `@runtest`, release checks, installed runtime, fleet throughput and matched
real-model task-completion uplift are **not executed by this change**. No latest
full-regression run is imported as evidence for this candidate.

## Fresh-process recovery boundary

The fixture first uses the worker and real lookup tools with a scripted reviewer
to retain an actual judgment, then writes the proof through the Goal store and
reconciles its phase. It deliberately stops before original commit/publication
ACK. This prepares an explicit interruption boundary; it does not kill a running
production server.

After leaving the parent's Eio context and reviewer override, the test starts
the same native executable with `Unix.create_process`. The child opens the private
workspace's durable originals, proof and registry in a fresh process. It requires
an unpublished run and retained judgment at entry, forbids every reviewer call,
and invokes the actual recovery drain twice. It checks terminal publication,
both ACKs, unchanged complete proof and no remaining recovery obligation. After
the child exits, the parent replays the registry and checks the proof and damaged
original again. A nonzero child status fails the test.

This is a controlled production-path fault-injection/recovery fixture. It is not
a newly observed production incident, a real-model quality comparison, an
abrupt-crash timing campaign or whole-server restart proof.

## Preserved limits and next work

Unclassifiable generic metadata remains a global discovery error. Selected body,
identity, digest, destination and root/successor failures remain errors. No new
authority index, silent skip, migration, retry cap or prompt control was added.

The next completion claims remain separate tracked work: rejection/correction/
delivery acceptance (task-2663), interrupted external effects (task-2184), matched
tool-observation outcomes (task-2664), and real G1 producer joins (task-2665).
This feature cannot by itself establish that MASC completes arbitrary delegated
work more reliably.
