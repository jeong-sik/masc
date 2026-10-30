# Standalone Skill tooling and historical verifier evidence

Current Task and Goal verifiers do not receive `keeper_skill`. They receive the
`report_review_verdict` report tool separately from the lookup tools provided by
`Verification_authority_tools`:

| Verifier surface | Lookup tools |
| --- | --- |
| Task, Keeper producer | `tool_read_file`, `tool_search_files`, `masc_web_fetch`, `masc_board_post_get`, `masc_fusion_status` |
| Task, workspace producer | `tool_read_file`, `masc_web_fetch`, `masc_board_post_get`, `masc_fusion_status` |
| Goal proof | `tool_read_file`, `masc_web_fetch`, `masc_board_post_get`, `masc_fusion_status` |

The lookup surfaces are constructed by `Verification_authority_tools.create`
and `create_goal_proof`. Task verification passes its lookups through
`Completion_authority_agent` to `Task.Anti_rationalization`; Goal verification
uses `Goal_verification_agent`. The shared reviewer supplies the report tool.
Lookup availability does not grant access outside the reader's evidence and
ownership boundaries.

`Standalone_skill_tools` separately advertises a workspace instruction catalog
as `keeper_skill` for standalone tool-using agents. Its `for_workspace` and
`of_snapshot` callers are currently tests; production verifiers do not call it.
`test_standalone_skill_tools` covers catalog publication, instruction body and
resource reads, frozen bodies, workspace isolation and composition exclusion.
These handler tests do not measure production verifier behavior or model quality.

A Skill supplies instructions, not evidence, permission or new tools. The
catalog and SKILL.md bodies freeze at the start of a run; resource files are read
live through the owned-file reader. The bundled
`skills/evidence-review/SKILL.md` remains an instruction fixture for this tooling.

## Historical Goal-verifier measurement

The [20260909 record](20260909/README.md) measured three synthetic Goal proofs
through the shared Task/Goal reviewer at installed binary commit
`05cf7d67be8ae46d2bde0c257a6af6be12404008`. That historical verifier wiring
offered `keeper_skill`: its recorded calls are historical verifier behavior,
not a measurement of a separate standalone-tooling caller.

All three expected verdicts matched, but strict tool-completion order passed
only 2/3, so the reassessed receipt's overall result is false. The original
receipt is retained alongside the reassessment. This is not a Task submission
measurement, a quality-improvement baseline, or evidence for current production
verifier wiring. Completion timestamps also cannot establish model consumption
order for calls in one batch, and observations lack model-attempt identity.

`scripts/harness/workload/standalone_verifier_skill_acceptance.py` is retained
only as the historical measurement runner. It creates Goal proofs and requires
an `evidence-review` Skill body read before the evidence read and verdict.
Consequently, it is obsolete as a current acceptance check: current verifiers
do not offer the mandatory Skill tool, so a correct verdict cannot satisfy it.
There is no current production acceptance command for this Skill workflow.
The old receipt-checker test has been removed; no current test validates that
runner's receipt checker. Reproducing the historical experiment requires the
recorded binary and its matching runtime configuration, rather than a current
build. The runner never builds its supplied binary.
