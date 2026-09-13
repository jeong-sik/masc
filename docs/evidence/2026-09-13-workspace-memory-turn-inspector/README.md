# Captured-turn inspector validation

The offline fixture suite covers exact turn/session/worker joins, complete trace
sequences, duplicate invocation coordinates (including other tools and proposal
IDs), tool completion outcomes, and system-prompt byte/hash integrity. It does not
claim native or installed feature acceptance.

The negative control uses the actual captured 851f412 exhibit-editor turn 502,
its exact provider input and raw trace. The expected publication IDs and fragment
are synthetic and were never written to the runtime. The inspector reports zero
fragment occurrences and zero exact-ID reads; semantic adoption stays unverified.
The actual captured bytes remain in the private archive named by validation.json.
Their SHA-256 values appear in negative-control-receipt.json. Related TurnRecords
and raw traces are also archived on the collaboration evidence branch in
2026-09-13-keeper-idle-input-baseline. Provider input includes private full history
and is intentionally not republished in this source evidence directory.

The receipt status inspected means input evidence was analyzed, not that curator
publication or Keeper adoption passed. Positive installed observation remains
required after candidate activation. See the matching audit document for usage
and the separate limits of provider serialization, tool completion and adoption.
