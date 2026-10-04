# Review response: schema constraints must be explicit

Baseline `2da38fc536be7ee9373edc5f3e06113d876bf1c8` checked the nonblank pattern
but not its string type; its closedness helper interpreted missing keywords as
false. The conclusion checks now require the string type and every synthesis
branch must explicitly declare `additionalProperties: false`.

A focused native OCaml 5.5.1 run compiled the actual Fusion Judge parser and
executed the unchanged Fusion consumer test function/helper slices, using the
exact production schema alias. The unmodified generated schema passes before
and after. Two injected schema faults (missing conclusion type and missing
branch closedness) pass the old consumer but fail the repaired consumer.
These fault cases test the consumer's detection, not a claim that production
currently emits those malformed schemas. before.json/after.json record results;
manifest.json identifies the source. The runner accepts candidate-checkout and
shared-checkout-cache paths as its two arguments.

The full consumer-file type check could not complete because cached Masc and
Operator_tool interfaces have inconsistent assumptions over Masc (typecheck-failure.txt).
The focused native slice passes, but it is not the full Keeper schema suite,
provider fallback or full product build. No CI or production execution ran.

JSON Schema's authoritative contract specifies that additional properties are
allowed when the keyword is absent, and string patterns constrain strings:
https://json-schema.org/understanding-json-schema/reference/object#additionalproperties
https://json-schema.org/understanding-json-schema/reference/string#regexp

The child was restacked onto the parent after its native-stack rebase to
`fe6964a5f55bd65db3bc2cdd96463fa2ee0e4f12`. That parent also changes unrelated
Librarian category fields. The focused native consumer run was repeated after
restacking; manifest.json records the final source files, and the same three
outcomes passed. The full-file cached-interface limitation remains unqualified.
