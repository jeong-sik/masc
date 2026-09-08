# Standalone verifier Skills

Task and Goal verifiers now receive the existing `keeper_skill` tool when the
workspace has published readable instruction Skills. The tool advertises the
workspace's instruction catalog; each verifier chooses a relevant procedure and
loads its body or bundled reference on demand. There is no role-name heuristic,
new preset, new environment variable, or duplicate Skill parser. The bundled
`skills/evidence-review/SKILL.md` provides a concrete verification procedure; the
existing embedded-skill seeder installs it as a missing package while preserving
operator edits.

The new connection is:

1. The shared Task/Goal reviewer hook reads the published workspace snapshot.
2. `Standalone_skill_tools` projects instruction entries using the same helper as
   Keeper's executable and advertised tool surfaces.
3. `run_named_with_masc_tools` preserves these native Agent-Core tools alongside
   the existing lookup and report tools. Invocation identity is not fabricated.
4. The original Skill reader serves the exact body or resource and sends every
   result to the existing verification observation callback.
5. The model uses its actual lookup tools for evidence and reports its verdict.

A Skill supplies a procedure, not evidence, permission or new tools. Composition
execution is excluded. Task Read/Grep/Web and Goal Read/Web capabilities retain
their existing scope. No snapshot or no readable instruction entries means no
Skill tool is advertised. Workspace-resolution failures are logged; missing
optional Skills do not suppress verification.

The catalog and SKILL.md bodies freeze at the start of the run. Resource files
are read live through the existing owned-file reader; they are not part of the
SKILL.md content revision. The catalog includes all workspace instruction Skills,
not a role-filtered or per-Keeper selection. New observations retain the exact
reference and returned metadata through the existing tool-result path.

## Verification

`test_standalone_skill_tools` uses the real published snapshot, native tool
handler, filesystem reference reader and observation callback. It exercises body
and reference reads, frozen bodies across refresh, stale-reference rejection,
path traversal refusal, unpublished catalog behavior, workspace isolation and
composition exclusion. This is executable tool-flow coverage, not a live model
quality measurement.

Targeted CI should run this suite and `test_keeper_task_skill_turn_exact`, which
covers the shared exact-reference/resource reader. The normal PR checks only
build `@check`; passing those alone does not prove these tests ran. No local Dune
build was run. `ocamldep -modules` was used only to check syntax.

This change does not add tools to Librarian, Board-attention or Effect exact-output
calls. Those calls remain bounded selection/judgment operations over supplied
inputs. Fusion's separate web-tool path is unchanged. Extending those roles needs
its own output-protocol and capability tests; a Skill instruction cannot invent
that execution surface. Deployment and model-driven Skill selection remain to be
verified after CI and release.
