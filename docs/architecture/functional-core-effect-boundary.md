# Functional Core / Effect Shell

This is the living implementation contract for new and refactored OCaml in
`lib/`, `bin/`, and `packages/agent_core/lib/`. RFC-0371 records the campaign
evidence; this document owns the lasting code shape.

The target flow is concrete and intentionally small:

```text
wire / env / clock / disk
          |
          v
resolve : Raw.t -> (Resolved.t, Resolve_error.t) result
          |
          v
decide  : State.t -> Resolved.t -> (State.t * Command.t list, Domain_error.t) result
          |
          v
execute : effects -> Command.t -> (Receipt.t, Effect_error.t) result
```

Do not introduce a generic monad transformer or application-wide Async layer.
Eio remains direct style; domain-specific `resolve`, `decide`, and `execute`
functions make the boundary visible in ordinary OCaml types.

## Meanings of absence and failure

- `option` means a value may genuinely be absent while the containing value is
  still valid. Each public optional field documents what `None` means.
- `result` means a named operation can fail in a way its caller can decide.
  Recoverable errors are closed variants until an HTTP, MCP, persistence, or
  logging renderer turns them into bytes.
- Missing, malformed, unavailable, and rejected are different states. Do not
  collapse them into `None`, a boolean, or a message that another in-process
  consumer must parse.
- Exceptions are for cancellation and defects the current layer cannot decide.
  A handler must translate a specific exception or let it unwind. In
  particular, `Eio.Cancel.Cancelled` is never turned into a default or domain
  error.

Use `let*` to sequence one `option` or one `result` happy path. It does not make
nested uncertainty clearer, and it does not justify mixing I/O with pure
decision logic in one chain.

## Resolve once, carry the value

Partial extraction and anonymous failure erasure are forbidden:

```ocaml
(* Wrong: validation and use can drift apart. *)
if Option.is_some request.owner then dispatch (Option.get request.owner)

(* Right: the boundary resolves one domain value. *)
let resolve_owner = function
  | Some owner -> Ok owner
  | None -> Error Missing_owner

let* owner = resolve_owner request.owner in
dispatch owner
```

- Do not add `Option.get` or `Result.get_ok`.
- Do not erase an error with `Result.to_option` or
  `Parse_outcome.to_option`. If a product boundary intentionally maps named
  errors to absence, implement an explicit policy function whose match and
  tests say which errors become `None`.
- `Option.value` is not globally forbidden. A default is valid when the owning
  boundary defines it as domain policy. Prefer a named resolver and an explicit
  match so the policy is reviewable.
- Do not validate a field, discard the proof, and inspect the raw field again.
  A private `Resolved.t` or closed variant should make invalid internal states
  unrepresentable.

## Pure decision cores

A pure module consumes time, randomness, identity, and configuration as
ordinary values supplied by its caller. It does not read the environment,
clock, filesystem, network, process state, random generator, mutable global, or
logger itself.

```ocaml
val decide : now:float -> State.t -> Command.t ->
  (State.t * Effect_command.t list, Domain_error.t) result
```

Only modules listed in `scripts/ocaml-pure-modules.txt` carry this mechanically
enforced promise. Grow that list after a module has a focused pure interface and
tests. Living entries cannot be removed, and there is no effect exception list
for a registered module.

## Eio, locks, and exact effects

- The creator of an `Eio.Switch.t` owns child fibers and resource lifetime. A
  live resource does not escape its switch.
- Snapshot immutable state while holding a mutex, release the lock, then do
  I/O, logging, callbacks, or awaits. State changes are pure transitions and
  the synchronization holder swaps or commits their result.
- Moving an effect outward must not weaken durable authority. Stores retain
  atomic state plus WAL/outbox/receipt commits; publish occurs from the durable
  receipt rather than a reconstructed guess.
- Invalid input produces no filesystem mutation, queue append, memory swap, or
  success SSE event.
- External formats are current-only and fail closed. Update every in-repo
  producer and consumer in the same PR; do not add compatibility readers,
  deprecated aliases, fallback shapes, or dual writes.

## Typed-tree gate

`tools/ocaml_boundary_audit` reads Dune-produced `.cmt` files and uses resolved
compiler paths. Aliasing `Option` cannot hide `Stdlib.Option.get`, while an
unrelated local module named `Option` is not a false positive. It also fails if
any production `.ml` lacks a typed tree, so an unwired source cannot disappear
from the audit silently.

The hard gate is deliberately narrow:

- partial extraction: `Option.get`, `Result.get_ok`;
- failure erasure: `Result.to_option`, `Parse_outcome.to_option`;
- canonical effect APIs inside explicitly registered pure modules.

The first two categories have an exact baseline keyed by source, lexical
binding, resolved callee, and count. It may only decrease. Pure-module effects
have no baseline and fail immediately.

The audit does **not** globally reject `Option.value`, catch-all handlers, or
every filesystem call. Those require ownership and data-flow evidence. Repeated
inspection of the same optional binding, cancellation absorption, and effects
inside critical sections become hard rules only as category-specific analyses
prove the bad flow without rejecting legitimate boundary orchestration.

CI runs the audit after the authoritative `@default @check @install` build:

```sh
bash scripts/ocaml-boundary-ratchet.sh
bash scripts/ocaml-boundary-ratchet.sh --json
bash scripts/ocaml-boundary-ratchet.sh --regenerate  # reductions only
```

## PR shape and proof

Use a small PR when one debt bucket can fall without changing a cross-module
contract. Use a larger PR only when the boundary type must cross all producers
and consumers together.

Every slice states:

1. which uncertainty or effect moves to which owner;
2. the characterization test that pins observable behavior;
3. unhappy paths proving resolution failure has zero side effects;
4. focused Dune targets for touched modules plus this boundary audit; and
5. source, exact-head CI, merge, deployment, and live evidence as separate
   claims.

## Sources

- OCaml distinguishes optional absence from explicit success/failure
  composition. [근거] [OCaml error handling](https://ocaml.org/docs/error-handling),
  checked 2026-08-12, confidence High.
- OCaml effect handlers are a low-level language mechanism; application
  concurrency here follows Eio structured direct style. [근거]
  [OCaml 5.5 effect handlers](https://ocaml.org/manual/5.5/effects.html) and
  [Eio documentation](https://ocaml.org/p/eio/latest/doc/README.html), checked
  2026-08-12, confidence High.
- Haskell `Maybe`/`Either` motivate composing one uncertainty value instead of
  reopening it branch by branch. [근거]
  [Data.Maybe](https://hackage.haskell.org/package/base/docs/Data-Maybe.html) and
  [Data.Either](https://hackage.haskell.org/package/base/docs/Data-Either.html),
  checked 2026-08-12, confidence High.
- Clojure's separation of immutable values from coordinated identity updates
  informs pure transitions plus an outer commit boundary. [근거]
  [Clojure values and change](https://clojure.org/about/state), checked
  2026-08-12, confidence High.
