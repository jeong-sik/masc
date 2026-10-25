# Composition output alternatives

Scope: the surviving producer-coverage portion of #33000 consolidated into
#25860 by comment 5903734367. Base: f44c6660d3a3fb400110956745a6a5375e04d446.

The current broad probe reaches a truncated task page and nonempty goal/run
items. Two new scenarios instead exercise actual Keeper handler alternatives:

- Tasks: empty snapshot, two-row page with limit=1, conditional `unchanged`,
  and a final continuation page with one distinct row and no next cursor.
  Every exact handler value passes the actual Plan.validate_output boundary.
- Metrics: a named missing fitness observation with null metrics/components,
  followed by a real pending record with nullable outcomes and nested observed
  fitness. Missing get_metrics is a tool failure, not a success-schema value.

Negative controls change only the actual first-page cursor field, retaining
all other real producer data. Renaming it to an undeclared key must produce
exact root Unexpected_field; a numeric next_cursor must produce the exact
String_type/Integer_type mismatch at that field. Plan.create retains its
canonical descriptor authority; tests do not inject alternate contracts.

The former metrics_json_with_resolution branch was removed by #45267
(0b3004be316); current metrics reads exact identities and does not append
resolution fields. That deleted path is excluded rather than reconstructed.
These scenarios do not claim complete conditional-field coverage of every
composable producer. Existing guest-runtime probes remain unavailable when
the guest runtime is unavailable; this change does not turn a skip into proof.

Parsing and whitespace pass. Independent source review and selected execution
are pending at record creation. No local Dune/typecheck, full regression,
live browser/guest/fleet, installation, merge or deployment evidence is claimed.

Run [40232184255](https://github.com/jeong-sik/masc/actions/runs/40232184255)
at bb95492d16edc37ae42ca8c0b550046fcba8e916 ran 120 cases with 10 failures.
The new metrics alternative passed. The new tasks scenario passed its real
producer alternatives but failed its original negative control: a supplied
modified descriptor is canonicalized to the registered contract by Plan.create.
Prior source reviews missed that behavior. The corrected controls mutate only
the observed cursor field through the canonical production plan, as above.
Other failures include unavailable browser Add-on observations; they have not
been isolated by a baseline run and are not reported as passing. Corrected
execution remains pending. This is not whole-suite success.
