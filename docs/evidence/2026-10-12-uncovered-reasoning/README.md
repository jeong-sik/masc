# Durable reasoning without streamed coverage

Base: `92a65185d3f395de222a1060ba6d287918f3cf8e`.

`held_turn_of_log` previously reduced streamed reasoning to a boolean. Any
nonempty fragment then suppressed the entire durable `Message_thinking` row.
History `rows_of_trace` combines exposed reasoning, withheld-step observations
and, for reasoning-only traces, omitted-step observations. The durable aggregate
has no streamed block identities. A fragment does not prove full coverage.

Remove the boolean and preserve durable reasoning regardless of streamed
presence. Do not infer duplicate coverage from text. Existing streamed reasoning
is retained too: until shared identities exist, overlapping exposed content can
appear in both records. This change prevents evidence loss; it does not claim
complete reasoning deduplication or alter reasoning visibility controls.

Bounded interpreted probe: `/tmp/masc-reasoning-coverage-20261012/parent.ml`,
`current.ml`, corresponding `.log` files. It executes the actual complete held
source constructor and suppression function with minimal log/row types and
source/thinking accessors. Parent exits 2 on partial reasoning suppression;
current exits 0 for incomplete/absent reasoning, unchanged speech ownership,
foreign typed source and missing-source controls. It does not execute full
history parsing, timeline assembly, renderer or providers.

Syntax-only parsing passed for production and two changed registered fixtures;
`git diff --check` passed. Registered fixtures were not executed. Existing
suppression fixtures now assert typed retained-role decisions instead of text or
row-order oracles; the assembly fixture also corrects a stale tool suppression
expectation inherited from the earlier receipt-coverage repair.

No local Dune build, full typecheck, CI, formal approval, merge, installed binary,
runtime or screenshot evidence is claimed.
