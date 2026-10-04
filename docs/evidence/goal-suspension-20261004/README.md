# Goal suspension evidence

Scope: D4 in #41014. Goal lifecycle, verifier admission and proof retention,
dashboard projection/controls, and TUI decoding/controls. Linked Tasks remain
independent. D3 feasibility appraisal is not implemented by this change.

Results: 24 native tests passed (7 suspension, 10 phase, 5 cancellation, 2 projection);
113 dashboard tests passed; complete dashboard TypeScript check passed.

The native runner compiles the complete candidate implementations for Goal phase,
store, verification ledger/admission, delivery, measurement, unavailable envelope,
Workspace_goals, workspace request identity/broadcast and Fusion request context.
It links unchanged dependencies from an existing OCaml 5.5.1 cache; this is not a
full product build. Reused public interfaces are admitted only when their source
matches the candidate. `--typecheck-consumers` additionally compiles the complete
candidate dashboard accessor/health/timeline, Keeper task-context codec and TUI
decoder (including its current usage dependency). Three required Keeper/verifier interfaces are refreshed without claiming
their implementations were compiled. See `native-manifest.json` for source hashes.

```sh
python3 docs/evidence/goal-suspension-20261004/check-goal-suspension.py \
  "$PWD" /path/to/existing-compatible-cache \
  --typecheck-consumers \
  --suite test_goal_suspension --suite test_goal_phase_all \
  --suite test_goal_drop_delivery --suite test_goal_suspension_projection
```

The suspension suite exercises the real filesystem, locked Goal transitions,
actual verifier binding entrypoint, proof ledger and effect outbox: all restore
states, cross-switching, idempotence, terminal refusals, Drop/Reopen, criterion
invalidation, bound proven/refuted results, exact-run replay rejection,
Candle-before-proof failure, and preservation of the human confirmation binding.
The phase suite retains its explicit legacy matrix and round-trips all eleven
full lifecycle values. Existing cancellation tests include fresh-process audit
recovery. The projection suite executes the server's public-action and audit
restoration projections.

Dashboard evidence: four Vitest suites and complete TypeScript check. The Chromium
probe renders the actual source GoalTree using Vite dev transformation and
synthetic HTTP. It verifies Pause/Resume/Block/Unblock requests and readback,
distinct counts, the saved restore state, and desktop/mobile controls. All three
screenshots were visually inspected. This is not an installed dashboard or a
live server mutation.

```sh
cd dashboard
./node_modules/.bin/vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 \
  src/api/goal-lifecycle.test.ts src/api/dashboard-goals.test.ts \
  src/components/goals/goal-tree.test.ts src/components/goals/goal-helpers.test.ts
./node_modules/.bin/tsc --noEmit
cd ..
node scripts/goal-suspension-browser-probe.mjs dashboard /tmp/FRESH_OUTPUT_DIR
```

Limits: no full server/TUI executable build, native PTY scenario, production
restart, CI, merge or deployment. TUI ordering/key tests are authored but unrun
as a full TUI test binary. A broader Goal-store/dashboard integration suite and
full dashboard OCaml endpoint check could not reuse the older cache because of
changed transitive Goal interfaces; they are not counted as passes. The actual
core modules and listed consumer modules have narrower successful evidence.
Independent agent review was unavailable because the existing review agents had
exhausted their quota. This is author self-review, not independent approval.

After #41134/#41136 merged, the branch was rebased onto main
`61e0d3ad9e000ac0788dd1d5e3a826217bdc50ef`. The 24 native cases, listed
consumer typechecks, 113 dashboard cases and whole dashboard TypeScript check
were rerun successfully on that base. The browser-tested Goal source files were
unchanged; its retained screenshots remain source-fixture evidence.


## Current main integration and idempotent-response check

Integrated main `6fc062feee7e33a271e09dc155d9feffee923704` cleanly. The
reported repeated Pause/Block object-phase response was not reachable at the
reviewed head: the public action dispatch enters `finish_goal_suspension`
before the generic `Already` handler. It returns the nested Goal with a string
phase and sibling resume phase. The response regression now checks both kinds
across all three restoration states, `noop: true`, and unchanged stored bytes.
No production response change was required. Constitution parity B8 now reflects
implemented suspension instead of describing it as absent.

The first regular focused Dune build exposed missing direct test dependencies
(Unix and Yojson; all directly used modules were then declared). After that
repair, the repository wrapper built `test_goal_suspension.exe`,
`test_goal_phase_all.exe` and `test_goal_suspension_projection.exe`; their native
executions passed **7 + 10 + 2 = 19** tests. Logs are retained locally as
`/tmp/pr41151-focused-build.log`, `/tmp/pr41151-focused-build2.log` and
`/tmp/pr41151-test_goal_*.log`. The first build failure is not counted as a pass.
Dashboard sources did not change between the earlier main base and this one;
the historical 113 Web tests and browser captures were not rerun. No full
server/TUI executable build, new PTY/browser execution, CI or deployment is
claimed by this integration.
