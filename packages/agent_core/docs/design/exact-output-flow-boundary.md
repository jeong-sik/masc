# Exact-output outer-flow boundary

Status: active pre-1.0 contract  
Effective: 2026-07-30

## Ownership

`Agent_sdk.Exact_output` is the single public surface for exact structured
output. OAS owns:

- immutable resolver snapshots and catalog-admitted opaque target handles;
- provider-wire admission and separately frozen candidate plans;
- one fresh outer-flow identity with immutable, preordered candidate visits;
- fresh, non-shared attempt identities;
- one-plan, at-most-one-dispatch `execute_once`;
- monotonic phase, dispatch-count, response, and provenance receipts;
- the ordered outer-flow transition to a predetermined successor;
- one pure semantic verdict per structurally successful candidate;
- immutable evidence for accepted results and typed semantic rejections.

The caller owns:

- domain input construction;
- domain schema, codec, and content validation;
- durable business-state binding, release, quarantine, and completion;
- operator configuration that names opaque candidate references;
- every durable business commit or replay policy after OAS returns.

The outer flow is generic. It contains no coordinator vocabulary and no
provider, model, tier, price, query-intent, or error-string policy.

## Immutable flow snapshot

An outer flow freezes one nonempty caller-declared candidate order, its
catalog-admitted opaque target handles, and one immutable domain input. Catalog
membership and credential outcomes are frozen, but credentials remain
unselected until their candidate is reached. Snapshot construction validates
only topology: candidate identities must be nonempty and unique.

The resulting order is immutable. OAS has no ranking store or process-local
history that can reorder a later snapshot. A caller that wants a different
order must construct a different snapshot explicitly.

Starting the flow allocates one OAS-owned outer-flow identity and precomputes one
immutable visit `(flow ID, 1-based ordinal, candidate identity)` for every
frozen candidate. This performs no credential selection, request admission,
call identity allocation, callback, or network effect.

During execution, OAS resolves the frozen credential outcome and prepares only
the current candidate. Successful request admission freezes one ready plan and
receives one fresh non-shared attempt. A target-selection or request-admission
rejection receives no plan, call ID, or execution receipt.

## Execution

`execute_flow_once` is affine. A duplicate or concurrent invocation cannot
dispatch. For each predetermined candidate:

1. OAS resolves only the current precomputed visit's frozen target and admits
   its exact request contract.
2. A typed target-selection or request-admission rejection receives an
   immutable candidate-rejection receipt fixed at `Before_dispatch` and
   `dispatch_count = 0`; it does not enter
   `before_dispatch`.
3. For an admitted candidate, the caller's `before_dispatch` callback must
   confirm its durable binding before OAS invokes the unchanged single-plan
   `execute_once`.
4. OAS may select the next frozen candidate only after one of these typed
   outcomes:
   - that candidate rejection receipt;
   - a first-use transport failure whose exact execution receipt is
     `Before_dispatch` with `dispatch_count = 0`;
   - an HTTP 413 request-body refusal recorded at `Response_received` with
     `dispatch_count = 1`;
   - locally detected invalid JSON after one structurally complete response,
     recorded at `Response_received` or `Terminal` with
     `dispatch_count = 1`.
5. The caller's `before_advance` callback receives the typed failure and
   the predetermined successor visit, and must durably confirm release before
   OAS prepares that successor.

Callbacks can stop a transition but cannot select, replace, or reorder a
candidate.

Advance eligibility is effect-based, not a classifier over rejection causes.
Every typed target-selection or request-admission rejection is pre-dispatch and
zero-dispatch, so it is eligible for the predetermined successor. OAS does not
infer that a credential, schema, or requirement rejection must behave
identically across opaque targets. Target-specific credential outcomes, schema
validators, and capability admission are evidence about the visited candidate,
not proof that an unvisited candidate must reject the contract.

The following outcomes are terminal:

- callback failure or exception;
- duplicate/replayed execution;
- cancellation;
- a missing execution prerequisite or frozen-request invariant failure;
- any dispatched response outside the two typed advance cases above;
- partial, tool, ambiguous structural-output, or non-JSON-contract exposure;
- a final typed candidate rejection, reported as `Flow_candidates_exhausted`;
- structural success.

After each structural success, OAS invokes the caller's pure `validate`
callback exactly once. `Accept` returns the accepted value and prior rejection
evidence. `Reject_and_advance` preserves the transport success and domain
rejection as immutable evidence, then advances directly to the predetermined
successor. A final semantic rejection returns a typed nonempty trace.

The two post-response advance cases may add one completion dispatch for each
subsequent declared candidate. This is explicit failover blast radius, not a
retry of the same candidate: every attempt remains affine and every successful
advance is retained with its exact failed and successor visits. Provider error
prose is diagnostic only and cannot authorize an advance.

OAS performs no domain commit, replay, ranking update, or lifecycle transition
after validation. Those effects remain behind the caller's existing domain
authority rather than a second exact-output Gate.

## Evidence

Every flow evidence projection carries:

- the fresh outer-flow identity;
- the caller-declared candidate identity snapshot;
- the monotonic typed candidate-visit count;
- ordered admission outcomes only for candidates reached so far;
- every non-shared execution receipt allocated for an admitted current
  candidate;
- every successfully confirmed candidate-admission rejection or typed
  transport-failure advance, bound to the failed visit and its predetermined
  adjacent successor;

After semantic validation succeeds, callers can project their accepted and
rejected domain values exactly once into a current-only durable transcript.
OAS preserves the declared candidate order, admissions, measurement receipts,
generation attempts, advances, semantic rejections, and final acceptance in
one integrity-bound snapshot. Decoding reconstructs evidence only; it never
reconstructs a live affine flow or performs a domain commit.

Terminal variants additionally carry the candidate's exact
rejection, success, or execution failure. The `admitted_flow_candidate` and
`flow_attempt_receipt` wrappers embed the same precomputed visit; a rejection
embeds that visit without fabricating a plan, call ID, or execution receipt. A
new `start_flow` always allocates a new flow identity; restart resume is
unsupported here and belongs to the caller's authenticated operation journal.

Every admission rejection and allocated outer attempt receipt carries the same
precomputed visit as the flow evidence. The flow identity, candidate identity,
ordinal, and one-shot receipt therefore form one private immutable record
binding; the caller cannot construct or splice that join from coordinator or
target strings.

After cancellation escapes, the same aggregate evidence remains queryable from
the opaque flow attempt.

The affine executor is the sole progress writer. Concurrent evidence readers
may observe the exact intermediate point after a successful request admission
is recorded and before that candidate receives its fresh attempt. Such a
snapshot is point-in-time evidence, not a fabricated attempt or a terminal
state.

`flow_execution_error_outward_dispatch` projects one closed fact about the
invocation returning the error: `No_outward_dispatch` or
`Outward_dispatch_started`. The fact says only whether that invocation began
its one outward completion dispatch. It does not claim provider acceptance,
response receipt, billing, physical execution, retryability, failover
eligibility, or any Pricing decision. OAS derives it from affine flow control
and private receipt state; callers do not decode phases, counts, HTTP status, or
provider policy.

## Explicit exclusions

- `execute_once` never retries and never changes plans.
- The outer flow performs no weighted, health, cost, or latency routing.
- Pricing is measurement evidence only and is absent from all decisions.
- Public flow rejections expose provider-neutral dispositions and capacity
  bounds only; provider, model, endpoint, credential environment, schema path,
  and raw serving-evidence source remain private to OAS.
- Resolver bootstrap and direct-execution diagnostics remain OAS integration
  surfaces, not MASC control inputs. MASC consumers may import only the outer
  flow's provider-neutral visit, disposition, receipt, and provenance
  projections.
- There is no legacy cascade API, compatibility wrapper, predecessor intent
  decoder, or persisted runtime JSON migration.
- There is no flow preference store, domain lifecycle, recovery store, or scope
  retirement implementation behind the public facade.
- Before 1.0, obsolete runtime assets are reset rather than reconciled.

Archived cascade documents describe an earlier ownership decision and are not
the active exact-output contract.
