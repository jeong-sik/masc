# Fusion schema consumer repair

Parent #41056: `a0a465f68ad8674ae8d05ffba5e1a06b9d18f9cd`.

The nonblank Judge repair moved the schema to a root oneOf so Answer/Recommend
can require nonblank conclusions while Insufficient may leave resolved_answer
empty. Keeper_structured_output_schema directly aliases that schema, but its
consumer test still called required_strings on the root. That helper fails
immediately with "schema has no required member". The parent's 11 passing
parser-slice tests did not include this consumer test.

The consumer now reads every synthesis branch. It retains the required fields,
all three decision kinds and nested consensus/contradiction checks, and verifies
the decision-specific conclusion constraints. Unrelated schema tests/helpers
are unchanged; the product decoder and Insufficient contract are unchanged.

Validation: ocamlc -stop-after parsing test/test_keeper_structured_output_schema.ml
and git diff --check pass. Native execution/typecheck/CI are unrun. The parent
native parser-slice evidence remains limited to its own recorded sources/tests;
this change does not claim that its consumer suite or provider fallback ran.
