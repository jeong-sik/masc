# Startup catalog fixtures must reach admission

Issue: [#27898](https://github.com/jeong-sik/masc/issues/27898).
This is a test repair, not a change to the production startup contract.

The atomic catalog publication runs at `1546b54953269fedb15d7e6d8f1a02c344585219`
and `e3d6f3bef78da14a0a89e1faca6929cd3f1dc5d3` each emitted three bootstrap
SKIP records. Their bodies spawned `main_eio` and attempted startup. Each
runtime fixture declared a table twice, and the child logged a TOML parse
error before the health/dashboard assertions. The failure path called
`Alcotest.skip`. The original logs and counts remain in the
[retained atomic publication evidence](../evidence/2026-11-02-catalog-atomic-publication/README.md).
They are not completed startup proof.

Removing the duplicate table alone would leave obsolete profile/route syntax.
`Runtime_toml` rejects `[routes]`; current routing declares a provider/model
binding and `[runtime].default`. `Runtime.initialize_degraded_loaded` validates
catalog membership before publication. Missing optional models can be excluded,
but a missing default cannot select a different runtime. The owner bootstrap
records invalid model configuration as `Runtime_startup_state.Setup_required`
while keeping owner-authenticated settings available. That is separate from
`Server_startup_state.Degraded`, which reports an owner auxiliary failure.

The replacement cases exercise three public subprocess/HTTP scenarios:

| Configuration | Required observation |
| --- | --- |
| The only declared runtime has an uncatalogued model | Owner readiness and HTTP 200 settings; `startup.model_runtime` is `setup_required/config_invalid`; no published default or runtime |
| A deployment declares capabilities for its default model and leaves one unreferenced model uncatalogued | Owner ready; model runtime available; health names exactly the excluded runtime; dashboard retains only the configured default |
| The same two bindings select the uncatalogued model as default | Owner ready and settings available; model setup remains required; diagnostic names the rejected default; no alternative default or runtime is published |

The positive model has an explicit `[models.stable.capabilities]` declaration.
The negative model has no such declaration and uses a fixture-specific API id
absent from the embedded catalog. Provider identity, model identity and endpoint
are separate TOML fields; the fixture no longer decodes a compound
`custom:model@endpoint` string or substitutes an endpoint after a split failure.

The three cases retain their registration positions but have changed fixture
bytes, names and assertions to match the current contract. A new successful run
would demonstrate these replacement scenarios; it would not be a same-fixture
production before/after pair. Failure to reach owner readiness now fails with
the child log instead of skipping. HTTP status and response content are both
checked, including the dashboard endpoint the old test name claimed to cover.

Local verification is OCaml parse-only and whitespace checking, not a local
build or typecheck. Focused CI for the complete bootstrap suite is requested
separately at the committed head. Until a terminal result is retained, this
document claims source changes only. Even a successful fixture run would not
establish real provider/account behavior, mixed account admission, native
implicit HOME behavior, installed runtime operation, or whole-stack integration.
The original issue remains open.
