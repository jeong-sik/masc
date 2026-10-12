# Explicit nonoperation turn source

Base: f3d759adce5bb5236934f0635e446b6dc25f5802.

`keeper_loop_tool_projection.persist_continuation` writes approval delivery keys
with explicit turn_ref. History retained turn_id but discarded execution_source
for these rows. Preserve the validated explicit Turn_ref source for canonical
Workspace_message, Fusion_run and Approval_lifecycle provenance without granting
an operation journal identity. Passive rows without turn_ref remain unowned;
autonomous marker alone cannot grant ownership to these delivery namespaces.
Malformed provenance remains unowned, and Operation identity keeps precedence.

Isolated artifacts: /tmp/masc-tui-nonoperation-turn-source-20261012/.
Unchanged parent/current execution_source_of_fields functions were interpreted
with minimal typed surroundings, accessor stubs, an operation selector stub and
a single-valid-reference parser stub. Parent exits 1 for lost explicit source;
current exits 0 across all three nonoperation keys, passive/invalid refusals and
canonical Operation precedence. Codec, producer persistence and whole history
pipeline were not executed by this harness.

Two changed files pass syntax-only parsing and diff whitespace checking. Existing
canonical wire fixture now checks source ownership but is unexecuted. Full
build/typecheck, runtime/UI/screenshots, CI, approval and merge are unverified.

Fixture audit found the inherited nonoperation assistant row used unsupported
`terminal_assistant`; corrected it to the canonical `terminal_result` codec
variant. The fixture still has not executed; malformed provenance is intentionally
unowned and cannot satisfy the positive ownership case.

## Stronger codec measurement

Artifacts: `/tmp/masc-tui-nonoperation-turn-source-codec-20261012/`.
The whole unchanged delivery identity codec and actual Turn_ref module are
interpreted with the parent/current source selector and its production helpers.
Checkpoint/trace-id/execution-id surroundings are minimal stubs; checkpoint
behavior is not under test. Actual Yojson types are loaded from the installed
library. Initial invocation failed to load Yojson; after loading yojson.cma,
parent exits 1 for lost canonical explicit source and current exits 0 for all
three delivery kinds with terminal_result, plus invalid terminal_assistant,
invalid Turn_ref and passive row refusal. This executes codec-to-source selection,
not full History.decode, producer persistence or visible UI.
