(** Set utilities — SSOT for the Hashtbl-as-set membership / set-difference
    pattern that saturated across perf PRs (telemetry, dedupe, distinct
    counters).

    Each helper is a one-pass [Hashtbl] kernel. We keep [Hashtbl.t] over
    [Set.Make(Key)] because (a) callers already pass arbitrary key types
    (strings, ints, tuples) without a functor instance, and (b) the linear
    O(N) bucket model matches the existing call sites' allocation profile.
    A future swap to [Set.Make] is a single-module edit. *)

val of_list_with : ('a -> 'b) -> 'a list -> ('b, unit) Hashtbl.t
(** [of_list_with key xs] builds a membership set keyed by [key x] for each
    [x] in [xs]. Duplicates collapse via [Hashtbl.replace]. One linear pass.
    Default capacity 16 (matches existing call sites). *)

val count_distinct : ('a -> 'b option) -> 'a list -> int
(** [count_distinct key xs] counts the number of distinct [Some k] values
    produced by [key] across [xs]. Elements where [key x = None] are
    ignored. Two-pass equivalent of [List.filter_map key xs |> List.sort_uniq
    compare |> List.length] but in O(N) time with no intermediate list. *)

val count_difference :
  'a list ->
  present:('a -> 'b option) ->
  absent:('a -> 'b option) ->
  int
(** [count_difference xs ~present ~absent] counts distinct keys produced by
    [present] that are NOT also produced by [absent], in one walk of [xs].
    Used to model [joined \ left] (active agents) or [started \ completed]
    (in-progress tasks) over a flat event stream. Replaces O(N x M)
    [List.filter ... List.mem] pipelines with two linear passes. *)
