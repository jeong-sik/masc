# Response pricing authority and Agent accounting

This decision implements the consumer hard cut requested by
[#27898](https://github.com/jeong-sik/masc/issues/27898) within the user's
oldest-first fundamental-repair goal. It does not amend runtime budget or
admission policy.

## Original contract and observed discrepancy

At parent `a736fe763b15be2366c7c8d22f0b24796bdeedf6`,
`Agent_turn.accumulate_usage` accepts provider config, response model and usage.
Its interface promises observational estimation. Missing response cost can
trigger a global catalog lookup and a second estimate, independently of
Complete's preceding annotation. Response labels are trimmed and can fall back
to the configured request model.

The initial repair `5e6793b467853e5da9b2db155e710d70283b0f78` captures price lookup
authority with the request. It still retains the second estimator. Independent
adversarial review found a P2: outer Complete attempts pricing before its own
`Complete_common.patch_telemetry` applies its explicitly display/routing-only
model fallback. A missing reported ID is therefore left unpriced by Complete,
but Agent can turn the display fallback into a charge. A padded ID can likewise
be rejected by the exact parser and then trimmed into a price by Agent.

Review of successor `c020f3610cc792886d42b316d93f25c96fe68b31` found another P2:
native HTTP streaming applies a lower display patch before outer Complete
annotation. Injected callbacks do not traverse that layer. Pricing must therefore
consume the typed `reported_model` observation rather than response display
text, independent of patch order. The existing Types interface explicitly says
that an unavailable observation does not authorize inference from response or
configured model labels. Production parsers/finalizers already capture it.

The first candidate's eight executed suites passed 518 cases, including the
original ten pricing cases; the provider-complete fixture failed to compile
because its migrated module reference was not qualified. That run does not
prove the absence of the newly found P2 or constitute overall test success.

The typed-observation candidate's ten suites executed 699 PASS/2 FAIL. All
nineteen pricing and six native HTTP pricing cases passed; the two failures
were older Anthropic image fixtures expecting real caller input to merge into
a tool result. Parent `a736fe76` independently reproduced both (99 PASS/2 FAIL).
The fixture-only successor asserts six exact roles, retains the native image
and tool payload checks, and checks the caller text separately, matching the
existing `Conversation`-origin contract. Test 41271100485 at exact
`ab7634fe1fe3297a86b21784e8e96acc4b189e1a` completed SUCCESS with 701 actual
passes across the same ten suites. Counts from other heads are not added.

## Authority and implementation decision

The issue requires consumers to use the resolved binding rather than
reconstructing provider/model policy. The constitution requires strict parsing,
explicit missing facts and no silent default inference. The actual producer
inventory has one production accumulator caller, fresh Pipeline collection.
All its sync/stream and injected transport paths return through Complete.

Complete remains the response-cost annotation authority. Its immutable price
source captures the original model catalog and effective provider permission.
It estimates only against a captured exact reported-model observation;
explicit absence and unavailable observation remain unknown. Raw custom
producers can stamp their model observation with `Types.with_reported_model`
before normalization. Provider-reported charges,
including zero, take precedence. Missing rates and required cache multipliers
remain unknown.

Agent accounting now consumes already-annotated observations: `Some cost` is
summed, while `None` remains a pricing gap. It no longer accepts provider config,
queries a catalog, trims model IDs into price identities or estimates a second
charge. A response model only names a diagnostic gap. Explicit standalone
`Pricing.estimate_cost` and read-only catalog inspection remain available.

The old estimator-specific helper fixtures are replaced by observed-charge and
unknown-cost fixtures. The existing omitted-model Pipeline fixture keeps its
lifecycle/routing assertions and now preserves the missing cost. Public
Agent.run cases cover captured positive pricing, missing selected rates,
missing/padded reported IDs and an explicitly reported zero. Missing payload
counts, known subtotals and prior gaps retain their existing contracts.

This is the implementation decision under the issue's authorized hard-cut
scope, supported by independent source and response review. Changed-head
approval and execution evidence must bind their own exact candidate; no earlier
review certifies the amended implementation.

## Evidence boundary

Current terminal recovery reuses already-collected state and skips collection
and accumulation. Terminal-resume repricing was considered during analysis but
was not established as a current defect. This change removes duplicate pricing
authority; it does not claim a newly reproduced restart failure, real provider
HTTP, installed runtime or Dashboard proof.
