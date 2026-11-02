# Typed model capability presets

Issue: [#27898](https://github.com/jeong-sik/masc/issues/27898).
This unit follows the captured native-account selection repair. It closes the
model preset carrier; it does not complete the original catalog hard cut.

Provider capability policy already carries `Capability_preset.t`. Model rows
still carried an optional string, and manifest entries wrapped a second private
string type. Applying a public model row could resolve an unrecognized string
to generic capabilities. Composition serialized the manifest's admitted value
back to a string before request projection parsed it again.

Both model and manifest entries now carry the same closed preset directly.
TOML/JSON boundaries retain their existing accepted spellings and reject unknown
ones. Composition and pure projection pass the typed value without another
lookup or an unknown-label fallback. The duplicate manifest string constructor
and renderer are removed. A caller constructing a public model row can select
only a declared preset variant.

Display and catalog evidence render the shared canonical spelling. Equivalent
aliases such as `openai` and `openai_chat` now produce the same exact-output
catalog evidence. The control compares public resolver snapshots for those
aliases and confirms that a different preset still changes the evidence.
Wizard image capability reads use the pure typed resolver and preserve its
optional declaration: an undeclared image fact remains distinct from explicit
false. Explicit row overrides retain upstream declaration provenance. Provider
identities remain separate; a preset is not an account or provider id.

This is a carrier change. Omitted model/manifest bases retain their existing
inheritance and baseline semantics. A read-only inventory at the parent source
finds 247 packaged rows and 13 without `base`: four chat rows and nine task-only
image/speech rows. Choosing an explicit policy for absence requires a separate
change; task-only rows must not acquire an inferred chat preset. Provider-scoped,
wire-preset and bare-row precedence remain unchanged here.

Validation is parse-only source checking, dependency inspection and independent
review at the committed head. Any focused Test request or result must name its
actual source. No real provider/account execution, installed runtime, full
regression or whole-stack integration is established. Historical evidence hashes
remain tied to their original serialization and are not reinterpreted as current
canonical output. The issue and its original acceptance checklist remain open.
