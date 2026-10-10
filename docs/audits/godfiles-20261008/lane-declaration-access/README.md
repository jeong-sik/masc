# Lane declaration access surface, 2026-10-09

Parent: `d3d148e5ae41ecfab1d7191bd2eaa1d491147537` (#42024).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Lane_addon_runtime.read_declaration` and `save_declaration` accepted optional
`caller` attribution but passed it only to `caller_access`, which ignored it.
Only host-owned typed `access` affects declaration read/write authority. The
unused public labels and helper are removed; no compatibility forwarding API
is left. The same `Unauthenticated` default now appears directly at each
optional access boundary. `dispatch` keeps its meaningful caller provenance for
delivery and fleet operations.

Tool and HTTP consumers retain their original trusted access calculation and
pass it directly. HTTP's caller variable still feeds `source_access`; the misc
tool's caller still serves subscription/dispatch provenance. Test composition
helpers lose their redundant caller argument. The editor fixture's own caller
remains because it constructs typed fixture access; it stops forwarding an
ignored label into production. Assertions and authority outcomes remain intact.

The runtime changes from 2,100 to 2,097 lines. This is an API responsibility
cleanup, not a full runtime decomposition. [source-comparison.json](source-comparison.json)
confirms the rest of the runtime equals the parent after the declared label,
helper and default-binding edits. Worker, configuration, retained record,
cleanup and fleet responsibilities remain pending in the original inventory.

## Consumer checks

| Changed interface | Direct verification | Executed result |
| --- | --- | --- |
| Declaration read/write API | Existing editor flows: Keeper/operator access, private owner refusal/reassignment, shared ownership withdrawal, CAS, malformed repair, direct-child paths and concurrent publication | 10 passed |
| Same API in private dependency graphs | Existing composition cases 5–7: source eviction and repair authority, pending owner replacement refusal, private graph read/save/repair and unauthenticated refusal | 3 passed |
| Tool and HTTP call sites | Focused build includes editor/composition targets and the HTTP route target | 3 executable builds passed |

[checks.json](checks.json) records exact commands, logs and executable hashes.
[source-sha256.json](source-sha256.json) records the changed files and relevant
authority consumers. The HTTP target is compile-only: its machine-live behavior
does not exercise declaration editing and was not run. No new tests mirror the
deleted parameter or implementation layout.

## Scope

These are focused macOS checks using temporary real TOML/ownership stores and
fake external workers. Provider execution, live Keeper continuity, HTTP behavior,
visible UI, installation, deployment, full CI and whole-stack approval remain
unverified. This is one bounded partial improvement, not completion of the
171-candidate campaign.
