# Dashboard API Contract

> Parse external data once. Business logic receives domain values, not wire
> guesses.

## Contract

Every response consumed under `dashboard/src/api/` must pass through an
explicit schema in `dashboard/src/api/schemas/` before it reaches a component
or domain function.

- The schema owns both runtime decoding and the TypeScript output type:
  `Schema.Schema.Type<typeof ResponseSchema>`.
- API programs return `Effect.Effect<DomainValue, TypedError, Service>`.
- Response interfaces, response casts, post-parse normalizers, permissive
  defaults, and generic `get<T>` at feature call sites are not allowed.
- Missing required fields, excess fields, invalid numbers, and unknown closed
  variants fail with a feature-specific schema-drift error.
- Request builders may keep dedicated input types. This contract governs
  external response data.

## Functional boundary

The standard runtime is Effect v3. Use `Effect`, `Schema`, `Option`, and
`Either` from `effect`; do not introduce another Option, Result, or schema
representation.

```text
HTTP / SSE / WebSocket / Storage unknown
  -> Effect Schema decode
  -> domain value or closed domain variant
  -> pure decision / projection
  -> ViewModel
  -> Preact
```

- Use `Schema.OptionFromNullOr` or `Schema.OptionFromNullishOr` when absence is
  part of the wire contract.
- Resolve absence at the use-case boundary when the business operation needs a
  value. Preserve `Option<A>` only when absence itself has product meaning.
- Compose with `map`, `flatMap`, and `match`; do not repeatedly convert the
  same Option to `null` or `undefined` across layers.
- Browser I/O and `Effect.run*` belong to runtime adapters. Pure business
  modules do not import browser globals or start effects.
- Transport, decode, and feature failures remain distinct tagged errors until
  the outer view/logging boundary maps them to operator text.

## Decoder policy

Decode with all errors enabled and excess properties rejected. Endpoint
schemas describe the exact producer currently shipped by this repository.

- Do not accept legacy aliases or repair old payloads in the frontend.
- Do not collapse unknown enum values to a plausible default.
- An additive producer field is a contract change because excess properties
  are rejected. The producer, schema fixture, and consumer must land together;
  a server-only additive response change is not compatible with this client.
- If backend and dashboard must change together, update the producer fixture,
  schema, and consumer in the same PR.
- If an independently deployed producer is incompatible, fail visibly and
  track the producer correction as its own issue/PR.

## Async resource policy

Preact controllers expose one discriminated `RemoteData<E, A>` signal:

- `Initial`
- `Loading { previous: Option<A> }`
- `Success { value: A }`
- `Failure { error: E, previous: Option<A> }`

Reads use latest-wins cancellation. A cancelled or older request cannot update
state. Unmount disposes subscriptions, timers, and the active Effect fiber.
Components must not maintain parallel `data`, `loading`, `error`, or inflight
Promise state for the same resource.

## Incremental conversion

Campaign progress and the shrinking legacy allowlists are tracked in #28260;
each migration PR links that issue and marks only its completed slice.

Each PR converts a complete endpoint or tightly related endpoint group:

1. Lock the producer shape with a positive fixture and drift cases.
2. Replace that endpoint's decoder with Effect Schema.
3. Return an Effect program from its API module.
4. Feed one `RemoteData` state from the feature controller.
5. Remove the endpoint's previous schema, nullable state, normalizer, and
   compatibility helper in the same PR.

Untouched endpoints may retain their current Valibot implementation while the
sequence is in progress. New endpoints and migrated endpoints use Effect
Schema only; a single endpoint never mixes both implementations.

## Verification

Every converted boundary includes:

- a complete current-wire success case;
- missing, excess, malformed, and unknown-variant failures;
- nullish-to-Option assertions where applicable;
- typed transport-error and schema-error propagation;
- cancellation and stale-completion coverage for its resource;
- a production bundle assertion proving Schema/runtime code does not enter the
  initial static closure unless the boot route requires it.

The PR description records focused tests, typecheck, lint, production build,
and bundle impact. Exact-head CI remains the merge authority.

## Endpoint note

`GET /api/v1/keepers/:name/chat/history` may include `delivery_key` only for
rows written through idempotent operation paths. Plain append rows omit it.
Consumers correlate accepted operations by exact `operation_id`; omission is
a real domain case, not a value to backfill.

Every history row — including autonomous-turn rows projected from typed turn
records rather than the chat store — must carry a non-blank `id`. The schema
(`keeper-chat-history.ts`) requires it and drops any row without one without
an error surface. #29108 restored the autonomous projection's id after it was
lost to a refactor that predated the required-id contract.

## Non-goals

- OCaml-to-TypeScript schema code generation.
- Duplicating backend request validation in the dashboard.
- Changing backend wire contracts as part of a frontend-only conversion.
