# Completed-history Librarian Addon evidence

The production durable queue now uses its configured `derive_memory` Addon.
The host retains the complete original source and preparation, resumes it before
fresh selection, validates the original host execution and captured absorption
journal, and publishes Memory under original source locks and an atomic Memory
basis comparison. Actual range receipts precede external ACK, both source
positions, and durable Finished. Uncertain original work never authorizes a
replacement request or another inference.

Latest completed selection: [run39899986422](https://github.com/jeong-sik/masc/actions/runs/39899986422),
exact `8bd78aa75f764fcf7c204a3d6512053f00586fb5`, **184 passed, 1 failed**.
Compilation succeeded. Atomic Current **155/155 in 7.953 s** and request progress
**16/16 in 0.142 s** passed; history **13/14 in 8.880 s** failed at the original
replacement's pre-admission read while the Addon was Off. The shared submit
state machine returned an unavailable export as an error instead of preserving
the unchanged original as waiting. The common repair and its actual-store
regressions require a fresh execution; this run is an overall failure.
[Exact-head receipt](history-basis-first-execution.json) and
[raw-log excerpt](history-basis-first-excerpt.txt) retain the failure.

The preceding completed selection: [run39897358407](https://github.com/jeong-sik/masc/actions/runs/39897358407),
exact `57b06a6ee933c7571caa509a4e57876e8b15fc98`, **34 passed**:
configured Addon owner **23/23 in 10.680 s** and completed-history integration
**11/11 in 3.826 s**. This verifies the review repair that isolates malformed
global inventory from valid queued Keeper wakes as well as the original history
pipeline. [Exact-head receipt](history-wake-repair-completed-execution.json) and
[raw-log excerpt](history-wake-repair-completed-excerpt.txt) preserve its scope.

The earlier history-only [run39896648638](https://github.com/jeong-sik/masc/actions/runs/39896648638),
exact `8fcdbca85b55883223c88c0cae4caa3e9ce9dfe0`, passed **11/11 in 4.606 s**.
[Its receipt](history-production-completed-execution.json) remains separate.
Subsequent basis-supersession and replacement-journal repairs require their own
execution; neither completed run certifies those later changes.

## Recorded execution

- Pending foundation: [run39889133529](https://github.com/jeong-sik/masc/actions/runs/39889133529),
  exact `a309cae82837b7f02d154df9bc6f696f16259d70`, six suites and **631 passed**.
  The preceding run39887902390 failed compilation on an unqualified test module;
  the qualification repair is part of this head. See
  [the foundation receipt](pending-foundation-execution.json).
- Python worker: **27 passed**, reported from the agent's actual subprocess tool
  result. Librarian used 17 process starts, 0.860 s total and 0.048–0.065 s each,
  including startup and fsync. The prior raw stdout was not saved as a file;
  [the reported receipt](python-worker-reported-execution.json) records that limit,
  command and exact source hashes. This is not a MASC/provider latency benchmark.
- To close that raw-log gap, the six Librarian cases were reexecuted on the
  unchanged worker source at exact `0bf669df54940552aeed51a941b67cede120c3a1`:
  **6 passed**, 17 real processes, **0.861 s total / 46.9–64.5 ms per process**.
  These timings include startup, differing request counts, fsync and exit.
  [Raw output](python-worker-reexecution.txt) and [all individual timings and
  source hashes](python-worker-reexecution.json) are retained. They measure
  worker protocol/persistence rather than provider or full host latency.
- The first new source-owner [run39892095882](https://github.com/jeong-sik/masc/actions/runs/39892095882),
  exact `c9c40295282b99c4768b00673ede8b53a60cbdad`, failed. Its requested list
  contained one nonexistent suite and compilation also found a fragile match
  in the source capture. The explicit match repair and corrected selection are
  retained in the later integration candidate.
- Production integration: [run39894327289](https://github.com/jeong-sik/masc/actions/runs/39894327289),
  exact `d22196b9e65e83df4d6aaacac40b716ee5dbdcfd`, requested ten concrete suites.
  Compilation passed. Execution ran **438 cases: 421 passed and 17 failed**.
  Seven suites succeeded completely, including the actual atomic Memory basis
  guard. Ten integration cases failed in fixture checkpoint setup, six capture
  cases used metadata refused by the canonical encoder, and the capacity
  fixture incorrectly marked its already-read baseline as a restart.
  [The exact-head receipt](history-production-first-execution.json) retains
  per-suite counts and timings. These failures require repaired fixtures and a
  fresh execution; the eleven integration cases are not yet a PASS claim.
- The repaired [run39895924935](https://github.com/jeong-sik/masc/actions/runs/39895924935),
  exact `0bf669df54940552aeed51a941b67cede120c3a1`, compiled all three selected
  suites. Capture **7 passed** and capacity callback **25 passed**. All eleven
  integration cases failed in the newly added nonempty external-admission setup:
  that API also needs the Eio fiber for its directory mutex. Its call-site
  repair keeps the real external item and final ACK=1 assertion. [The second
  exact-head receipt](history-production-second-execution.json) preserves this
  failure separately; another execution must verify the repaired integration.
- The terminal-refusal/attachment repair was selected in
  [run39906960166](https://github.com/jeong-sik/masc/actions/runs/39906960166),
  exact top `794ccac949f59e9bc2085d8656e8b9b4617498ae`, with only
  `test_keeper_librarian_durable_execution` requested. Compilation stopped at
  line 392: `Unbound value Refresh.run_durable`; no case executed. That helper
  is private. The repaired attachment fixture uses the public
  `submit_durable`, joins the actual serialized Memory lane and observes a new
  `last_measurement` instead. It also checks that the production queue leaves
  source progress, originals, provider calls, Memory and continuity unchanged
  while the Addon is absent. Parsing and source checks do not establish native
  compilation or execution; a new exact-head run remains unverified.

## What the eleven integration cases exercise

Actual configured Runtime, the persistent Python worker, host Exact HTTP and
server authorization, the serialized Memory lane and actual filesystem stores
are used. Resource launch/cleanup and the provider HTTP endpoint are fixtures.
Cases cover checkpoint-only, official-only, mixed, production Pending and result
wakes, Off before first Gate intent, real Memory receipts followed by failed
ACK and local Off recovery, rewritten checkpoint, same-trace restart, purge and
actual worker replacement, and destructive Memory epoch reset. Unknown/pending
work has no resubmit permission. A separate three-case Current suite checks
stale revision, changed complete facts at the same revision, and fresh-basis
publication under the actual write locks.

The integration fixture disables absorption-model judgment, while still using
its real captured journal/replay and disabled-policy result. It does not prove
paid provider or absorption-model execution, real Docker, installed native
binaries, visible Dashboard/TUI or live Keeper memory continuity. History
capacity/failure descent, other Librarian purposes and the original E03/54-item
acceptance criteria remain separate. No live server was replaced.
