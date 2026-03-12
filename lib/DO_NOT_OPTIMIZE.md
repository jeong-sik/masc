# DO NOT OPTIMIZE

`lib/void.ml` contains a few intentionally minimal helpers. This note exists so those helpers are not "improved" into something with different semantics.

## Public behavior

```ocaml
val contemplate : 'a -> 'a
val dissolve : 'a -> unit
```

- `contemplate` is an identity helper. It must return the input unchanged.
- `dissolve` is a discard helper. It must not introduce logging, cleanup, or hidden side effects.

## Why keep them minimal

- Call sites rely on these functions being transparent and predictable.
- Tests and examples use them as explicit boundaries, not as extension points.
- Adding behavior here would make surrounding code harder to reason about.

## When to edit this

Edit the module only when at least one of these is true:

- the public contract in `lib/void.ml` is intentionally changing
- examples or tests need a new observable behavior
- the helper is being removed or replaced

If you change the behavior, update the code and its call sites together and leave a technical rationale here.
