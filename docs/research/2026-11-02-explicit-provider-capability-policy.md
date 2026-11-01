# Explicit TOML provider capability policy

Issue: [#27898](https://github.com/jeong-sik/masc/issues/27898).
This unit addresses TOML provider capability declarations and their selected
request projection. JSON missing-field admission and the rest of the original
issue remain open.

The atomic publication owner made whole-pair selection coherent, but its model
seed projection still used `capabilities_base` or, when absent, the provider id.
That conflated an omitted field with policy. In particular, the packaged OpenAI
Chat row intentionally omitted a provider-wide preset so an unknown model could
not inherit another model's structured-output or reasoning support. Selection
nevertheless derived a preset from its `openai` id. Raw observation and selected
binding could therefore disagree about unknown-model policy.

`Capability_preset` now owns one closed preset vocabulary and its accepted input
spellings. A provider has one `capability_policy`: `Models_only` or
`Provider_defaults {base; by_identity_kind}`. Only the latter carries typed wire
presets. A typed record or `Model_catalog.with_provider_entry` cannot retain
hidden wire overrides when switching to `Models_only`. The TOML parser requires the capability field in
addition to the existing required id/kind/endpoint/path/auth fields. Missing,
empty, padded, mistyped or unknown declarations fail before snapshot admission.
`models_only` cannot simultaneously grant a provider-wide wire override.

The OpenAI row states `capabilities_base = "models_only"`. Selection never
derives capability policy from the provider id. Snapshot, registry and runtime
binding metadata represent provider-wide absence as `None`, and a registry
capability predicate skips that absence. Selected unknown models retain absent
request policy. Exact admitted model rows still determine model capabilities,
thinking controls and prices. Existing permitted bare-row and wire override
precedence remain governed by their explicit declarations.

The pure profile resolver consumes typed presets directly. Model-row base
labels retain their existing parse boundary, but provider preset resolution no
longer serializes a provider id or wire kind into a label. The accepted preset
spelling list is shared with model/manifest validation instead of duplicating
an allowlist and resolver. Exact-output catalog evidence renders the typed
policy canonically, including sorted wire overrides; equivalent preset aliases
now have the same rendering. That evidence identity change is not an execution
result.

Twelve positive producer rows require migration. Identity, exact-output,
browser, HITL and probe rows state `models_only`, retaining model-owned facts
and their former raw absence. The isolated per-keeper Ollama Cloud fixture
states its intended provider contract instead of relying on old id inference.
A legacy-key negative row also supplies the new required field, so that its
rejection still depends on the retired key. Existing rejected-input controls now reject
missing policy during decoding, before an opaque invalid selection can exist.
They do not claim to force an invalid current snapshot.

The first complete source review found eight missing producers and a typed
record bypass. The initial AST inventory recognized only one of the parser's
two string-literal print formats and missed ordinary escaped strings. The
corrected inventory includes both formats and `bin/`, rather than treating
that incomplete inventory as proof. The bypass is repaired structurally by
putting wire overrides inside the `Provider_defaults` constructor.

Public controls cover all six required field omissions, malformed capability
declarations, refusal of a model-only wire override, raw and selected unknown
models, discoverability without fabricated provider capabilities, exact model
policy/pricing, and the packaged OpenAI known-versus-unlisted model boundary.
A public typed-view control starts with a real wire preset, switches its
declaration to `Models_only`, admits that view, and checks absent unknown-model
policy on both wires. The snapshot suite has 29 registered cases.
The three startup fixtures also explicitly clear `AGENT_CORE_MODEL_CATALOG`,
addressing the parent fixture review's environment-isolation P3. Their embedded
catalog premise cannot be replaced by an inherited external file.

Local validation is parse-only/source inspection and whitespace checking. It
is not a local build/typecheck or executed admission proof. A focused Test run
must be tied to its committed checkout before claiming execution. No real
provider/account, native implicit HOME, installed runtime, full regression or
whole-stack integration is established by this unit; no issue is closed.
