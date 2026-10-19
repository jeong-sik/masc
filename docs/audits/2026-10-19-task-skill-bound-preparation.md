# Task Skill bound selection and preparation

Source comparison base: `00e7c2210c6475188fbe66c116980e909034c4ef` (#43761).
This is a source-derived Before/After, not a measured preparation hotspot or timing.

## Finding and implementation

Executable setup, effective surface and Composition continuation called Task Skill
descriptor binding and then `prepare_surface` with the same immutable inputs. On a
reused selection, binding already validated the original snapshot and descriptor
objects; the preparation call repeated that `prepared_matches` check. On rebinding,
resolution had just constructed selection and preparation together, but the caller
recovered/revalidated the preparation through an optional field.

The canonical `bind_surface` returns `(selection, preparation)` in Result. Its
reuse guard preserves both the original selection-authority comparison and exact
prepared snapshot/descriptor validation. Changed/mixed/unbound inputs use the
same exact-reference resolver and return the preparation it constructs. The
resolver's functional result projection supplies either selection-only or paired
output at construction, avoiding a throwaway paired container in ordinary resolve
calls. The output is not recovered with a partial Option operation or a new error.
The projection cache itself keys snapshots and every ordered descriptor element
by physical identity (`Preparation_snapshot_key` / `Preparation_descriptor_key`).
Consequently a resolver-produced preparation belongs to those exact supplied
inputs even on cache reuse; returning its paired result does not assume equality
of a revision label or public Tool name.

| Boundary | Before | After |
| --- | --- | --- |
| Three executable consumers | Bind selection, then obtain preparation | One checked selection/preparation result |
| Retained-input `prepared_matches` calls per combined binding | 2 | 1 |
| Selection-authority comparison | Existing check | Same check |
| Rebuilt selection | Preparation already built, then checked again | Return the resolver's coherent product |
| Derived catalog/diagnostic/inventory | Already shared per owned projection | Same objects and weak ownership |
| Successful retained-surface observation | Once after binding | Once after binding |
| Typed resolution error | No preparation handed onward | Same error and caller mapping |
| Per-Task display observation | No pin rebinding | Same `prepare_surface` contract |

The old selection-only binding interface is removed from `.mli`/`.ml` and all
callers. `prepare_surface` remains an active observation API for `exact_task_surfaces`
and standalone preparation observations; it does not authorize execution or rebind
pins. No compatibility alias, cache, identity key, permission gate or numeric
control limit is introduced. Original source/descriptor objects, Task ids and
weak projection/product cache lifetimes remain unchanged.

`Retained_turn_surface` still means the successfully bound consumer retains its
preparation, including a product just constructed during resolution. Projection
and Task_product observations still distinguish construction from cache reuse.
Errors produce no successful retained-surface event. Executable_setup phase
observation and `core_error` / continuation `hold_task_skills` mapping remain.

## Authored feature scenarios and limits

Existing exact binding and dynamic Add-on/inventory scenarios are extended to use
the paired result and cover interleaved preparations, shared Task pins, merged
bound/unbound/source selections, changed descriptor authority withholding a
composition in both selection and returned catalog, changed/unreadable snapshots,
an unrelated no-pin Task observing an unreadable source without stale Skills,
attach/detach/replacement owner decisions, and one completed retained-surface
observation per successful binding. Existing durable setup-phase and effective
surface fixtures migrate to the canonical API. Three test files change; no new
standalone helper test/case, wording/layout/snapshot-output or PTY assertion is
added. All scenarios remain unexecuted.

Eight OCaml source/interface files are eligible for parsing-only checks. No local
Dune/typecheck/tests, CI dispatch/watch, model/native run, install/restart, live
prompt/config write, independent approval, own merge, runtime/paint or performance
verification. Diff/changelog metadata checks are distinct from feature execution.
The source count is scoped to retained-input combined binding: it is not a 50%
reduction in total preparation, network/model calls or Task completion time.
Matching list containers can take constant-time identity paths; distinct containers
holding the same descriptor objects avoid one repeated linear comparison. Output
projection/callback costs remain unmeasured. Catalog construction was already
shared, so it is not newly reduced from two builds to one.

Extra filesystem/network/model calls, Tool executions, UI rows, clock sources,
request generations, retries and knobs: zero. Fresh external callers can still
resolve a selection then bind it at a separate boundary; direct paired fresh
resolution is a follow-up, not claimed here as eliminated. Entire preparation/
discovery reuse, cold-start input/readability/observability, Ask-to-original-Task/
useful-work, resource-owned Composition, held-job/shared-backend and matched
Before/After scope remains active, preserving failed/cancelled/interrupted/
unfinished samples.
