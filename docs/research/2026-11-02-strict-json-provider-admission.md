# Strict JSON provider admission

Issue: [#27898](https://github.com/jeong-sik/masc/issues/27898).
This unit follows the explicit TOML provider policy change. The original
issue's remaining startup, account and native execution requirements stay open.

The JSON boundary previously inferred the wire kind, request path, no-auth
decision and a generic capability profile. An omitted declaration could become
execution policy even though TOML rows already required explicit decisions.
JSON now requires id, kind, endpoint, request path, an auth object with type,
and capability policy. Missing and null required fields reject the whole
catalog. Gemini alone may explicitly declare an empty request path. Optional
metadata retains its declared absent/null behavior.

`capabilities_base="models_only"` is an explicit absence of provider-wide
capabilities. It accepts absent, null or empty capability overrides and rejects
every nonempty override object, including a field whose value is null. Named
presets decode through the shared closed `Capability_preset` vocabulary.
Snapshot admission preserves the optional profile directly. A JSON model-only
replacement revokes an existing seed preset; it cannot regain that preset from
the provider id. Exact model capabilities and prices remain available.

`Provider_catalog.entry.auth` is the sole credential carrier. The redundant
`api_key_env` record field has been removed; empty and padded environment names
remain rejected for both keyed constructors. Public typed entry admission also
validates a `Chat_template_token` through the shared lossless token codec, so
it cannot bypass the JSON boundary's token validation.

Source inspection also found three fields accepted by the closed capability
object but never applied: chat output budget field, tool schema conformance
and inline reasoning. They now decode and override the profile. Assistant
prefill already had decoding and application; its behavior is retained.
Controls cover every accepted enum value, both prefill boolean values and
malformed input, along with required-field omission/null, no-policy propagation,
seed-policy revocation, exact model policy/pricing and typed token validation.

Existing fixtures now state their policy. Metadata-only fixtures use
`models_only`. Fixtures that previously exercised the generic profile state a
named preset with explicit false overrides for its differing flags, retaining
their former synthetic baseline. Negative controls retain their original
malformed field, duplicate key or collision as the rejection cause. The Muse
account file's unrelated `providers.meta` JSON is not a provider catalog.
Structured pipeline and supported-model controls retain explicit full profiles.

Local validation is source parsing, dependency inspection and whitespace
checking; it is not a local build, typecheck or executed admission proof.
Independent source review and any focused Test receipt must name their exact
committed source. This unit establishes no real provider/account execution,
installed runtime behavior, full regression or whole-stack integration. No
issue is closed.
