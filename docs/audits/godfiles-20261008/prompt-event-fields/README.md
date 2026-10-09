# Unified prompt event field boundary and render fixture

PR #42106. Base b79897fca8b237b212f02dba0aeeeaa4953dd909.
Production code head 82638889673ba61dad351d7d28bba861d8410d50.
Fixture repair head 746f8553ced68a40db8d0e390ed4997c595a79fe.

The original prompt owner combines pure typed event selection/quoting/grouping with template catalog reads, task/config/world observation, prompt assembly, logging and metrics. Private keeper_unified_prompt_event_fields owns Board and approval fields, row quoting, scheduled automation fields and schedule grouping (341 lines). Root keeps every acquisition/template/assembly effect. The current parent root has 2260 lines; after this split it has 1922. The original campaign baseline is 2226 and is retained in the inventory. Crossing below 2000 is not semantic completion.

Public keeper_unified_prompt.mli and existing For_testing contract are byte-identical. All extracted function/type bodies and retained root body match the parent after removing exactly the four extracted blocks, normalizing the helper's final newline and adding its private import/header. Schedule groups stay abstract in the private signature. No field, template prose, grouping policy, compatibility reader, timeout or performance claim was added.

Focused builds completed exit 0:
- `opam exec -- dune build test/test_keeper_delegate_completion_wake.exe test/test_keeper_wake_turn_context.exe`
- `opam exec -- dune build test/test_keeper_unified_verification_surface.exe`
- The latter was rebuilt after the fixture repair, also exit 0.
Wake-turn context was compiled only; its suite was not run.

Delegate executable `--color=never`: 10 PASS, run HNV97B24, exit 0.
Initial surface executable (with MASC_CONFIG_DIR pointing at the checkout's config): 25 PASS/18 FAIL, run 2JT7M23M, exit 1. Prompt_defaults.init only scans an already registered Prompt_registry markdown directory; the suite registered none, so template prose was absent. The environment variable did not register that directory. The failing overview is retained in surface-initial.output; the historical executable hash was not captured.

The fixture now unpacks Embedded_config prompts into a new temporary directory with Managed_asset_sync.No_edit_layer, checks installation failures, explicitly registers that directory, initializes the catalog and cleans the temporary assets at exit. It matches actual catalog bootstrap and uses no live prompt overrides or Keeper state. Production rendering and test assertions were unchanged.

Rebuilt surface executable `--color=never` without the config environment override: 43 PASS, run ERT3BAK9, exit 0. The 53 distinct successful cases (delegate 10 + surface 43) cover quoted external fields, reactions/votes, full delegate reply preservation, typed schedules and digest grouping, exact current approval authority and ephemeral world-state separation. Incarnation separation was verified by source review; the executed grouping case changes the digest while preserving the incarnation. No live Keeper/provider or UI was exercised.

The candidate remains partially improved: template/config acquisition, remaining context assembly and metrics need deeper semantic audit. The full 171-candidate campaign remains open. Evidence does not claim installation, full CI, live runtime, formal GitHub approval or merge. REST stack membership is dynamic and must be refreshed for integration.
