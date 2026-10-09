# Read coordinate decoding before filesystem effects

PR: [#41932](https://github.com/jeong-sik/masc/pull/41932).
Base: `da579cd105c15a4d3d62ad150adf5ea00fb79dbf`.

The Read schema admits JSON integer literals, but `Safe_ops.json_int_opt` ignored
`Intlit` values and treated them as missing. Present malformed values also became
missing; fractional numbers and numeric strings were coerced. An out-of-range
integer offset therefore read from line 1 and returned success. The owned Read
consumer is the production verifier's filesystem boundary; the Keeper sandbox
Read consumer uses the same parser through its own backend.

Two new scenarios failed before consumer wiring. A schema-accepted integer
literal coordinate requesting lines 2 and 3 returned all five file lines. An
offset of `99999999999999999999999999999999999` returned `ok:true`, `offset:1`
and the full file head. [before.log](before.log), [before-invalid.log](before-invalid.log)
and [before.json](before.json) retain the observed output and source identities.
At that checkpoint the pure parser and guidance declarations existed but were
unused; the runtime still used its unchanged coercing parser.

`Keeper_tool_read_window.of_args` now owns pure decoding and typed argument
errors. Only an absent offset defaults to line 1; only an absent limit is
unbounded by line count. Native integers, representable integer literals and
finite integral JSON numbers retain their exact coordinate. Wrong types,
nonfinite/fractional numbers, nonpositive values and unrepresentable integers
are caller errors. The upper bound is the native index representation, not a
new product quota. Non-object argument bodies are rejected.

Both runtime consumers decode before resolving paths or acquiring file bytes.
The effect edge maps typed errors to managed guidance and `Policy_rejection`;
the existing slice, path ownership and byte-budget contracts are preserved.
The private copied `fs_guidance` variant is removed. It was absent from the
runtime interface and had no external callers; constructors now come directly
from the guidance owner. New error templates are source assets only; no live
Keeper prompt or runtime data was changed.

| Boundary | Actual verification |
| --- | --- |
| Published Read schema to owned Read content | Schema validation/translation and exact file bytes for integer literals and integral numbers |
| Owned and sandbox Read invalid-input result | Both handlers reject wrong types, out-of-range integers, fractional/nonfinite numbers and non-object arguments; no file content is delivered |
| Existing zero-limit and file-coordinate slicing | Selected existing consumer scenarios |
| Owned file resolution | Existing `test_owned_read_cwd` scenarios |

The renderer initially threw while trying to JSON-encode a rejected nonfinite
number. [intermediate.log](intermediate.log) records that failed check. It now
retains the invalid value's JSON type when the standard encoder cannot encode
it, so an argument rejection remains a normal failure result. Tests exercise
that error path through both production handlers.

Five selected Read scenarios passed, including 52 invalid coordinate/backend
combinations, two schema-to-content representations and both non-object callers:
[after.json](after.json), [after.log](after.log). Thirteen owned-reader scenarios
passed: [owned.json](owned.json), [owned.log](owned.log). The local narrow Dune
executions also compiled the changed modules and their direct test consumers.

Commands, exits and elapsed time are recorded next to the raw logs. These are
operator-authorized focused local checks, not full CI or a full repository build.
The successful content scenario uses the real ownership-based file reader with
an isolated temporary root; sandbox invalid-input scenarios finish before backend
acquisition. Actual successful Docker/microVM/SSH reads remain outside that proof.
The existing sandbox-readable-file scenario failed because the configured fixture
image `masc-sandbox-test:ci` is absent locally (`image_not_found`).
[sandbox.json](sandbox.json) and [sandbox.log](sandbox.log) retain the actual
Docker error. It is not reported as a passing sandbox check.
All other responsibilities of the filesystem Godfile remain pending. `max_bytes`
coercion and full sandbox execution are not changed or certified by this unit.
