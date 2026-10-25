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

A negative control removes only next_cursor from the actual tasks descriptor,
then feeds the unchanged real first-page response to Plan.validate_output.
It must report exactly Unexpected_field next_cursor at the root. This
recreates the historical producer/schema drift without fabricating output.

The former metrics_json_with_resolution branch was removed by #45267
(0b3004be316); current metrics reads exact identities and does not append
resolution fields. That deleted path is excluded rather than reconstructed.
These scenarios do not claim complete conditional-field coverage of every
composable producer. Existing guest-runtime probes remain unavailable when
the guest runtime is unavailable; this change does not turn a skip into proof.

Parsing and whitespace pass. Independent source review and selected execution
are pending at record creation. No local Dune/typecheck, full regression,
live browser/guest/fleet, installation, merge or deployment evidence is claimed.
