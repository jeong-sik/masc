# Functional Core / Effect Boundary

This document is the implementation contract for new and refactored OCaml
code in `lib/`, `bin/`, and `packages/agent_core/lib/`.

The target shape is simple: decode external uncertainty once, make decisions
with domain values, then execute the resulting effects at an explicit shell.
`Option`, `Result`, and Eio each keep one meaning instead of becoming generic
wrappers carried through every layer.

```text
wire / env / clock / disk
          |
          v
decode + validate : raw -> (command, decode_error) result
          |
          v
decide            : state -> command -> (transition, domain_error) result
          |
          v
commit + publish  : effects -> transition -> (receipt, effect_error) result
```

## Semantic zero

- `option` means that a domain value is genuinely absent. It does not mean
  malformed, unauthorized, timed out, or "an exception happened".
- `result` means that a named, recoverable operation can fail. Error variants
  must retain the information needed to decide, retry, reject, or report.
- Eio is direct-style structured concurrency. Fibers, switches, clocks, paths,
  and network capabilities belong to the effect shell. Do not create a generic
  `Async`/`Result` stack around the whole application.
- Exceptions are reserved for cancellation and defects that the current layer
  cannot decide. A layer that catches an exception must either translate a
  specific exception into its own error type or re-raise it. Catch-all handlers
  are not a recovery policy.

`let*` is sequencing syntax, not permission to retain nested uncertainty. Bind
an `option` or `result` at the boundary where its meaning is known, then carry
the validated value. When a computation truly remains optional or fallible,
keep that type and compose it without repeatedly destructuring the same value.

## Parse once, decide once

Partial extraction is forbidden in production paths:

```ocaml
(* wrong: validation and use can drift apart *)
if Option.is_some request.owner then
  dispatch (Option.get request.owner)

(* right: resolve the boundary once and carry the domain value *)
let resolve_owner = function
  | Some owner -> Ok owner
  | None -> Error Missing_owner

let* owner = resolve_owner request.owner in
dispatch owner
```

The following rules are mechanical:

- Do not add `Option.get` or `Result.get_ok`.
- Do not erase a `result` with `Result.to_option`. If failure really becomes
  absence at a product boundary, expose that policy as a named function whose
  type and tests state which errors become `None`.
- A default is valid only where it is the domain policy. Put that decision in a
  named resolver such as `effective_timeout`, implemented with an explicit
  match. The ratchet forbids every new `Option.value` while existing ambiguous
  defaults are being classified and removed.
- Do not decode the same external field in several business branches. Decode
  into a private/closed domain type, then make the branches exhaustive over
  that type.
- Avoid `option result`, `result option`, and tuples of independent optional
  fields as long-lived internal state. Normalize them at the boundary into a
  closed variant that represents the valid states.

## Pure decision core

A pure module may consume time, randomness, identity, and configuration only
as ordinary values supplied by its caller. It must not read the clock,
environment, filesystem, network, process table, or random generator itself.

Prefer interfaces of this form:

```ocaml
type command
type transition
type domain_error

val decode : Yojson.Safe.t -> (command, decode_error) result
val decide : now:float -> state -> command -> (transition, domain_error) result
```

Effect shells own Eio capabilities and resource lifetimes:

```ocaml
type effects =
  { commit : transition -> (receipt, persistence_error) result
  ; publish : receipt -> unit
  }

type execute_error =
  | Domain_error of domain_error
  | Persistence_error of persistence_error

let execute effects state command =
  let* transition =
    decide state command |> Result.map_error (fun error -> Domain_error error)
  in
  let* receipt =
    effects.commit transition
    |> Result.map_error (fun error -> Persistence_error error)
  in
  effects.publish receipt;
  Ok receipt
```

The record above is a narrow capability boundary, not a service-locator. Add a
capability only when the use case needs that effect and keep the pure decision
function independent of it.

## Concurrency, cancellation, and exact effects

- The caller that creates an `Eio.Switch.t` owns its child fibers and resource
  lifetime. Do not return a live resource beyond that switch.
- Never perform blocking I/O, `Eio.Promise.await`, or callbacks while holding a
  mutex. Snapshot immutable state under the lock, release it, then perform the
  effect.
- Do not turn cancellation into a domain `Error` or a default value. Cleanup
  may run, but cancellation must continue to unwind.
- A pure transition is not a completed effect. Preserve the repository's
  exact-effect contract: validate first, commit state and the durable outbox as
  one authority, then publish. Retry and recovery use the durable receipt, not
  a reconstructed guess.
- External formats are current-only and fail closed. A decoder accepts the
  canonical schema or returns a typed error; it does not guess legacy shapes.

## Automated boundary ratchet

`tools/ocaml_boundary_audit` parses the OCaml compiler AST, so comments and
string literals do not create findings. It scans all production `.ml` files in
the three roots named above and reports:

- partial extraction (`Option.get`, `Result.get_ok`);
- failure erasure (`Result.to_option`, `Parse_outcome.to_option`);
- implicit defaults (`Option.value`);
- catch-all exception handlers; and
- effect calls in modules registered as pure.

The pure-module registry is `scripts/ocaml-pure-modules.txt`. The exact semantic
baseline is `scripts/ocaml-boundary-baseline.tsv`, keyed by file, lexical
binding, category, and callee. CI requires an exact match and compares the
committed baseline with the PR base revision, so a manual edit cannot conceal
an increase. When a refactor removes debt, regenerate and commit the smaller
baseline. The tool refuses to regenerate if any bucket increases.

```sh
bash scripts/ocaml-boundary-ratchet.sh
bash scripts/ocaml-boundary-ratchet.sh --json
bash scripts/ocaml-boundary-ratchet.sh --regenerate
```

The audit deliberately does not pretend to prove data flow or effect safety.
Repeated inspection through aliases, ownership, cancellation, atomicity, and
whether a default is valid remain semantic review and test obligations. The
pure-module check recognizes the canonical fully-qualified effect APIs; module
aliases and locally abstracted capabilities still require review.

## PR slicing and definition of done

Use small PRs when one semantic bucket can fall without changing cross-module
types. A larger PR is justified only when the boundary itself crosses modules,
such as introducing a closed command type and moving persistence behind its
consumer.

Every refactor PR must:

1. state which uncertainty or effect moves to which boundary;
2. preserve observable behavior with focused tests before changing structure;
3. add unhappy-path tests proving malformed/absent input has no side effect;
4. run the focused Dune targets for touched modules and the boundary ratchet;
5. update the baseline only downward; and
6. keep source behavior, CI status, merge state, and deployed-runtime evidence
   as separate claims.

## Design sources

- OCaml 5.5 error handling defines `option` for absence and `result` for
  explicit success/failure composition. [근거] [OCaml documentation — Error
  handling](https://ocaml.org/docs/error-handling), checked
  2026-08-11, confidence High.
- OCaml effect handlers are a low-level mechanism; application concurrency is
  kept in Eio's structured, direct-style API. [근거] [OCaml 5.5 manual — Effect
  handlers](https://ocaml.org/manual/5.5/effects.html) and [Eio 1.3
  documentation](https://ocaml.org/p/eio/latest/doc/README.html), checked
  2026-08-11, confidence High.
- Haskell's `Maybe` and `Either` instances motivate composing one uncertainty
  value rather than reopening it in each branch. [근거] [base 4.22
  documentation](https://hackage.haskell.org/package/base/docs/Data-Maybe.html)
  and [Data.Either](https://hackage.haskell.org/package/base/docs/Data-Either.html),
  checked 2026-08-11, confidence High.
- Clojure separates immutable values from coordinated reference updates; the
  same separation informs pure transitions plus an outer commit boundary.
  [근거] [Clojure reference — Refs and
  Transactions](https://clojure.org/reference/refs), checked 2026-08-11,
  confidence High.
