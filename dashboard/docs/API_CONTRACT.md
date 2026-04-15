# Dashboard API Contract

> Schema at the boundary. Drift = hard error, not `undefined` access.

## Why this exists

On 2026-04-15 the FSM Hub started rendering with
`Cannot read properties of undefined (reading 'data_record')`. The
`/api/v1/keepers/:name/composite` response had shipped without a
`recovery` field for weeks — PR #7334 removed it from the OCaml backend
(`lib/keeper/keeper_composite_observer.ml`). The dashboard TypeScript
`interface KeeperCompositeSnapshot` still declared the field as
required, and every unit test used a mock fixture that also declared
it. No test exercised the real fetch path.

PR #7412 patched the symptom with a hand-rolled
`normalizeKeeperCompositeSnapshot` that backfilled the missing fields.
That stopped the bleed but didn't stop the next drift. This contract
generalizes the fix into a rule.

## The rule

Every module under `dashboard/src/api/` MUST route its fetch response
through an explicit schema exported from `dashboard/src/api/schemas/`.

- The schema is the **single source of truth** for both runtime
  validation and the TypeScript type: `type T = v.InferOutput<typeof Schema>`.
- No hand-written `interface` for API response shapes. (Input types
  for request builders stay as interfaces; the rule applies to
  response parsing.)
- The fetch helper calls `parse...` / `v.safeParse` before returning.
  Parse failure throws a typed error (e.g. `CompositeSchemaDriftError`)
  carrying the valibot issue list with paths.
- Backward tolerance — optional fields, legacy aliases, enum fallbacks —
  lives **in the schema**, not in a post-hoc normalizer.

## Library: valibot (locked)

- Small (5-15 KB tree-shaken), designed for modular imports.
- `v.InferOutput<typeof Schema>` derives the TS type.
- Named imports only: `import { object, boolean, picklist } from 'valibot'`
  — no default or barrel imports. Bundle size delta must be stated in
  every PR that touches schemas.
- Do not reintroduce zod / hand-rolled validators. If a schema need
  exceeds valibot's surface, raise it as a follow-up issue before
  adding another dep.

## Drift policy

When the backend changes a response shape:

1. **If the PR lives in this repo** — it updates the matching
   schema in the same commit. A schema change that adds or removes
   a field is a reviewer-visible delta.
2. **If the dashboard ships before the backend catches up** — the
   parse throws `...SchemaDriftError`. The dashboard logs at `error`
   level and shows the operator view as unavailable. We do NOT
   silently backfill to a plausible default.
3. **Unknown enum values** — use `v.fallback` where forward-compat
   matters (new state variants landing on backend first). A
   well-named fallback is safer than a hard error when the frontend
   lags by days, but every `v.fallback` must have a comment explaining
   why hard-fail isn't acceptable here.

## Pilot endpoint

`/api/v1/keepers/:name/composite` — see
`dashboard/src/api/schemas/keeper-composite.ts`. The schema defines:

- Phase / turn / decision / cascade / compaction enums with explicit
  fallback for unknown values (backend may ship new states before
  frontend).
- Structural contract for `measurement`, `invariants`, `last_outcome`.
- `CompositeSchemaDriftError` with issue paths for debuggability.

The pilot landed in the same PR that removed the dead recovery UI
surface and retired the #7412 normalizer. Tests live in
`dashboard/src/components/fsm-hub.integration.test.ts` under the
`composite snapshot schema` describe block.

## Rollout

Other endpoints migrate in follow-up PRs (tracked in #7441). One PR
per endpoint or per tightly related group, never a mega-migration.
Each migration PR:

1. Adds `dashboard/src/api/schemas/<endpoint>.ts`.
2. Replaces the response `interface` with `InferOutput<typeof Schema>`.
3. Routes the fetch through the schema's `parse*` function.
4. Adds at least one positive shape test and one drift-rejection test
   to the relevant integration test file.
5. States the bundle size delta in the PR description.

## Non-goals

- OCaml → TypeScript codegen. Evaluated separately; parity with a
  running OCaml signature is hard to maintain without infrastructure
  we don't yet own.
- Schema-first mocking for all tests. Integration tests still prefer
  fixtures that match the schema, but unit tests for pure derivers
  continue to use mock observation data.
- Validating request bodies. The backend is the source of truth for
  request schemas; duplicating them in the dashboard is waste.

## FAQ

**Why reject on drift instead of normalize?**
Because #7412 showed what silent normalization buys us — the dashboard
stays up, but it renders a panel whose state can never change, and the
mismatch lives in the codebase until someone notices by eye. A hard
error forces the drift into a review instead of a render.

**What about the cost of a parse per fetch?**
Parsing the composite payload with the valibot schema is on the order
of microseconds in the hot path. The composite endpoint is already
8-second cache-bound on the backend (#7443); dashboard-side parse cost
is below the noise floor.

**What if I need to accept legacy shapes during a rollout window?**
Encode the tolerance in the schema with `v.union` /
`v.optional` / `v.fallback` and add a comment citing the date
the tolerance can be removed. Do not add a pre-parse normalizer.
