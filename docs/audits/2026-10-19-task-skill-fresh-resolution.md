# Fresh Task Skill resolution and preparation

Comparison base: `c275059790e1d5580134fd596b2f76f942eb4b68` (PR #43767).
This records source changes, not executed behavior or measured speed.

## As-Is / To-Be

`keeper_effective_tool_surface.project` resolved fresh references when no selection
was supplied, then bound that just-created selection. Composition continuation
did the same for the original activation's bound Task references. Both resolutions
had already constructed the selection and immutable preparation from the same
snapshot and descriptor objects.

`Keeper_task_skill_turn.resolve_surface` now returns that pair directly using the
existing resolver's output projection. These two fresh paths consume it without
entering the retained-selection guard. A supplied effective-surface selection
still goes through `bind_surface`; it may have different frozen inputs or Tool
authority. Ordinary executable setup also retains that binding contract.

| Source boundary per successful operation | Before | After |
| --- | --- | --- |
| Fresh effective-surface reference resolution | Resolve, then bind | Resolve paired product |
| Continuation with original activation | Resolve original references, then bind | Resolve original references to paired product |
| `prepared_matches` for those fresh paths | 1 | 0 |
| Separate `same_descriptors` selection-authority comparison for those fresh paths | 1 | 0 |
| Supplied-selection binding guards | Both exact-input and authority checks | Same checks |
| Continuation without original activation | Empty binding resolves; no prepared-input check | Empty reference resolution; no prepared-input check |
| Successful retained-surface access | 1 | 1 |
| Failed resolution retained-surface success | 0 | 0 |
| Catalog, diagnostics and inventory | Already shared by immutable preparation | Same objects and weak ownership |

The fresh API accepts references, not a caller-supplied selection. Its outputs
are created together by `resolve_requests`, whose preparation cache is keyed by
physical snapshot and ordered descriptor objects. There is no stale input to
validate after construction. This does not remove an authority guard on an
existing selection or on a real Tool call. Cache lookup and construction still
run as before; zero retained-input checks does not mean zero preparation work.

The original reference-only paths carried no Task ids on selection rows, and
the new path preserves that. Continuation source Task, sealed request, run and
activation provenance remain in their original owners. Config rejection,
unreadable configuration/source/entry, stale pins, unprojectable entries and
`hold_task_skills` mapping are unchanged. No original activation still resolves
empty references, including an unreadable configuration with no pins.

`Projection` and `Task_product` still report actual construction/reuse.
`Retained_turn_surface` remains a successful retained access after resolution,
including newly constructed products; it is not proof of a warm cache hit or
execution. `prepare_surface` remains the observation-only boundary for already
selected exact Task display without re-resolving pins. Selection-only resolution
remains available for constructing unbound observations before binding.

No new I/O/model calls, Tool executions, global caches, settings, limits, clocks,
request generations or UI rows are introduced. No claim of a second catalog
build removed, total preparation percentage, loading time or first-input gain.

## Authored behavior scenarios

Scenarios are authored but unexecuted under the current code-only instruction.

- The effective-surface shadowed-reference scenario compares a fresh exact pin
  and the supplied frozen selection, checks the same callable Tool set and exact
  shadowed instruction, and captures one successful retained preparation. An
  explicitly supplied empty selection cannot borrow fresh reference arguments.
- Existing preparation sharing, interleaving, weak ownership and cancellation
  scenarios obtain the direct fresh product. The typed unreadable-configuration
  failure also uses that route and must not become a retained success.
- The real owned-job nested continuation repair scenario captures unavailable
  original evidence as failure without retained success, restores and publishes
  the evidence, then captures completed preparation while the original child
  and parent consume their saved results. Existing assertions retain original
  Task identity, a distinct physical recovery request and zero backend replay.
  Both original-run and Skill-publication fault variants remain in the suite.

Only parsing and diff/changelog hygiene are checked in this author session.
Typing, assertion execution, CI, native/model runs, runtime observations,
installation/restart, visible UI and matched performance remain unverified.
Independent review and merge are separate; no author self-approval or merge.
