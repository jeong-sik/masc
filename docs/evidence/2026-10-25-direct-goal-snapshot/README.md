# Direct-turn Goal snapshot response

Source premise: Native #45750 layer #45774 at `72299fef6638a6804db4143673689c6e18791747`, direct base `d654f49cebac4498e6e03e6d33533105299f1a1e`. Review CR5638620234 observes two Goal-store reads that may disagree.

The direct turn now captures the existing typed Goal summaries once and maps their IDs into the world observation. `observe_direct_keeper_msg` requires that Result and performs no second Goal-store read. `Error unavailable` remains the original error; only authoritative `Ok []` is empty. The existing revision-bound measurement and held-task-link behavior remains in the original producer.

Run from the repository root:

```sh
python3 scripts/check-direct-goal-snapshot-component.py --source-ref 72299fef6638a6804db4143673689c6e18791747
python3 scripts/check-direct-goal-snapshot-component.py
```

The probe compiles verbatim production capture bindings, the direct-turn helper and world builder, and the Goal-summary producer. A scripted store changes its result between reads. Before: both compile and 7 of 8 behavioral checks fail (run exit2), including closing, opening, replacement, late failure and terminal filtering; the original unreadable path remains distinct. After: all8 checks pass (run exit0), one Goal-store read, matching IDs and summaries, preserved measurement failure. Nominal Goal data types, phase predicate, workspace/measurement I/O and unrelated world dependencies are fixture stand-ins.

This is source/component evidence, not a complete project typecheck, real concurrent persisted-store mutation, full Keeper/Host/SDK/vendor execution, installed-runtime result, formal approval or whole14-stack verdict. No Dune build or CI watch was performed.
