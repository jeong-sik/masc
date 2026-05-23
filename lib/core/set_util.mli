(** Set utilities — SSOT for the Hashtbl-as-set membership / set-difference
    pattern that saturated across perf PRs (telemetry, dedupe, distinct
    counters).

    Each helper is a one-pass [Hashtbl] kernel. We keep [Hashtbl.t] over
    [Set.Make(Key)] because (a) callers already pass arbitrary key types
    (strings, ints, tuples) without a functor instance, and (b) the linear
    O(N) bucket model matches the existing call sites' allocation profile.

    backing representation needs to change, hide it behind an abstract
    type [`'k t`] in this interface first. *)

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

val of_list_with : ('a -> 'b) -> 'a list -> ('b, unit) Hashtbl.t
(** [of_list_with key xs] is a Hashtbl-as-set keyed by [key x] for every
    [x] in [xs]. Building block used by [count_difference] and by
    test/test_set_util.ml fixtures. *)

val count_distinct : ('a -> 'b option) -> 'a list -> int
(** [count_distinct key xs] counts distinct [Some _] keys produced by
    [key] over [xs]. *)
