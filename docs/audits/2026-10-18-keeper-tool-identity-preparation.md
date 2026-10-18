# Keeper name validation preparation

Source comparison baseline: `97997af26ef5c0ada4d284af514207d578182492`.
Scope: tool membership validation during one frozen Keeper setup and per-Skill
schema-byte profiling. Existing immutable Task/catalog/descriptor reuse remains
the preparation authority; this change adds no cache or revision-based authority.

| Boundary | Before | After |
| --- | --- | --- |
| Common descriptor/Skill names for two model surfaces | Derived twice | Derived once per setup |
| Composition membership, `C` declared entries, transient drafts enabled | `2 * (C + 4)` schema-only Tools | No schema-only Tools |
| One composition Skill's byte profile | Declared schema plus four discarded shared controls | Declared schema only |
| Deferred builtin and attached-tool identity rules | Applied separately for each model surface | Same separate rules |
| Executable schema/handler construction and model request bytes | Required by actual runtime delivery | No reduction claimed |

Counts describe source paths, not observed allocations, durations or speedup.
Names and schemas share typed row selection, including async controls when named
async work exists without transient drafts. Byte profiling retains the exact
name + description + serialized input-schema accounting; shared controls and
request-envelope framing are excluded from each Skill's component bytes.

The existing bundle/effective-surface feature scenario now compares each
composition profile with the actual executable Tool's schema-component bytes.
The catalog scenario now requires named async controls while transient draft
Tools are absent. Both scenarios are authored and unexecuted. Parser checks,
whitespace checks and changelog validation cannot establish typing or behavior.

Remaining product work includes original Ask-to-Task useful-work resumption,
ordinary and nested/dynamic/effectful resource-owned Composition, typed held-job
reactivation, shared backend batching, and first-usable-input/Loading visibility.
Matched Before/After must preserve task/provider/tool conditions and original
execution identity, use comparable clocks, and retain failed, interrupted,
cancelled and unfinished samples. Source delivery, independent approval, merge,
installation, runtime continuity, visible TUI and measured latency remain
separate evidence stages.
