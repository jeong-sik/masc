# Settings retained-session integration

Remote source: `5d673773d03b1cf9008a01543cb1e3833c9f02ea`.
Actual published parent #41191: `6fade962e1a7ce36baadfe440816943310b225a8`.
Tested source tree before evidence addition: `e70fe1e11f72e43da5ae5956b5669350a433f994`.
Fresh REST readback still names this remote head; REST omits the stack key.

The remote author already replaced mount-owned write state with a whole session
keyed by exact accepted workspace authority. This integration preserves that
implementation: attachment-owned reads and unsent cancellation, retained sent
writes/unknown outcomes, write-attempt fencing, and neutral source invalidation
for an unknown response. The earlier separate uncertainty-only response was not
merged and remains untouched in its own worktree.

## Integration choices

Three source/test merge conflicts were resolved semantically:

- Keep the remote Settings session and attachment lifecycle. Observe the parent's
  shared committed signal only for its current authority and source generation.
  Pass it through `refreshOnObservation`; pending and uncertain writes keep their
  locks. A verified file commit also requests a source-inclusive snapshot,
  preserving the parent's four-reading refresh contract.
- Keep both sets of test imports and all parent and remote regressions. Remove a
  duplicate import. The parent exact-activity failure fixture now explicitly
  returns the typed activation failure because the remote suite mocks the resume
  helper globally; its original failure/receipt/refresh assertions remain.
- Preserve the parent's clean-source/authority retry in RuntimeTomlSession while
  retaining the remote neutral wording for a source-generation change. Such a
  change may mean an unknown write, not a proven commit.

Browser verified-receipt notifications and no-model-resume behavior remain from
#41191. Typed Settings writes retain their existing single model-setup resume.
No other production repair was needed after these integration choices.

## Actual local checks

Three prior actual-API regressions were ported, with semantics adapted to the
remote implementation, and all pass:

1. A sent POST retained across remount keeps controls disabled. Its later lost
   response remains uncertain; another writer's committed notification cannot
   silently clear it. An explicit source-inclusive read is required.
2. A write failing while no Settings view is mounted invalidates source bases,
   emits no confirmed commit/resume, and remains locked on remount until the fresh
   file read completes.
3. A detached unsent token intent is cancelled. A permitted new write can then
   become uncertain; the old token's late completion sends no second POST and
   cannot replace that newer uncertainty or increment its invalidation again.
   The old two-sent-write scenario is intentionally impossible with the new gate.

Final **275 tests / 9 focused suites PASS**, TypeScript PASS, scoped ESLint PASS.
The initial combined run was 274 PASS/1 failure from the resume fixture mismatch
above, plus a duplicate-import typecheck failure. Raw attempts are preserved.
These are not new product RED claims; the remote author's ownership repair
already satisfies the three causal regressions.

No native source/build files differ from the published parent; no native build
was run. No browser rerun, full suite, real server/model execution, CI, live
configuration change or deployment is claimed. Original-author historical
Settings/browser evidence remains preserved; it does not attest this final
integration. This worktree is frozen for root review without push or posts.
