(** Set utilities — SSOT for the Hashtbl-as-set membership / set-difference
    pattern that saturated across perf PRs (telemetry, dedupe, distinct
    counters).

    The one currently exported helper is a one-pass [Hashtbl] kernel.
    [Hashtbl.t] is used over [Set.Make(Key)] because callers pass arbitrary
    key types (strings, ints, tuples) without a functor instance, and the
    linear O(N) bucket model matches existing call sites' allocation
    profile. If the backing representation needs to change, hide it behind
    an abstract type [`'k t`] in this interface first. *)

(** [count_difference xs ~present ~absent] counts distinct keys produced by
    [present] that are NOT also produced by [absent]. Implementation: one
    pass over [xs] populates both the [absent_set] and [present_set]
    tables, followed by a single [Hashtbl.fold] over [present_set] that
    skips keys also in [absent_set]. Used to model [joined \ left] (active
    agents) or [started \ completed] (in-progress tasks) over a flat event
    stream. Replaces O(N x M) [List.filter ... List.mem] pipelines with
    O(N) work. *)
val count_difference
  :  'a list
  -> present:('a -> 'b option)
  -> absent:('a -> 'b option)
  -> int
