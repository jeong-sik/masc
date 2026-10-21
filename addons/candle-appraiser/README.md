# Candle appraisal worker

This package owns durable Grade, per-task Relation, and Weights judgment intents.
It does not own the Candle ledger, payout policy, final settlement or provider
credentials. The host must fully decode a returned answer against its original
`Candle_appraisal.request` before deciding a ledger effect.

This is the worker component of the extraction. Production Candle bootstrap is
not connected to it in this implementation unit. Its consumer request-schema
grant depends on the Browser Addon stack; use the declared dependency rather than
assuming the inspected older main has that API.

The `candle_appraise` tool submits or reads a request without waiting for a model
inside its RPC. Submission requires the admitted `operator` caller envelope;
the host still checks visibility and exact worker ownership. `lane_call` and
the two host request/result control tools are not exported to agents.

The tool schemas use the host-supported object union subset. Only Relation
requests carry `task_id`; only finished replies carry `result`.

Each intent retains the payout identity, stage, original Relation task ID, input,
schema and rendered prompt before it can appear in `lane_host_requests`.
Only the rendered prompt is sent as a model message; audit identity is not extra
grading evidence. Configure each named output through the existing installation
Exact route. The package baseline and request-schema grant remain mandatory.

The persistent state directory contains one versioned record per request. Reads
validate the complete record and input digest. Reusing an ID for different input
or replacing an already retained terminal result is refused. A new incarnation
on the same installation state can continue a pending intent or read its original
result. `outcome_unknown` is terminal: it never becomes a fresh model request.
Initial store creation syncs the installation parent before admitting work.
Missing or replaced storage is an error, including individual reads.
Directory sync failure makes that running worker refuse further reads/listings;
it cannot advertise an unconfirmed write as a completed judgment.

The complete pending listing must fit the manifest's actual reply frame. A new
intent that would exceed it returns `capacity_wait` without being stored; existing
work can finish before the host retries admission. A reduced frame that cannot
carry retained work refuses the listing explicitly instead of silently hiding
pending requests.

`lane_observe` exposes pending/finished counts and request IDs. When an ID list
would exceed the declared reply frame, counts remain available and the output
explicitly identifies the individual-read path. A finished request means a
terminal Exact result was retained; it does not mean a grade passed domain
validation, money was paid, or a Goal completed.

Build the optional container from the repository root:

```sh
docker build -f addons/candle-appraiser/Dockerfile -t masc-lane-candle-appraiser:0.1.0 addons
```

The host mounts the package at `/addon` and its installation-owned persistent
state at `/state`, using the existing container/engine ownership contract.
Provider keys do not belong in this container.

Focused subprocess checks use scripted host results, not real provider answers:

```sh
python3 -m unittest discover -s addons/tests -p test_candle_appraiser.py
```
