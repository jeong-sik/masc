(** Runtime lane — ordered candidate list for keeper turn failover.

    [id] is the lane's own name, the [\[runtime.lanes.<name>\]] table key. It is
    chosen by the operator and carries no structure; a keeper assignment or a
    route id names it to walk the lane. Candidates are opaque runtime ids
    ("provider.model" binding keys).  The [Runtime] module resolves ids to
    materialized runtimes, keeping this module free of the [Runtime] dependency
    cycle. *)

(** Candidate ordering strategy for a failover lane.

    - [Fixed]: every Keeper walks [candidates] in declared order from index 0.
    - [Spread_by_keeper]: each Keeper starts at a deterministic cyclic rotation
      of [candidates] derived from its Keeper name, distributing concurrent
      Keepers sharing one lane across distinct entry candidates while keeping
      each Keeper sticky to its own primary and preserving the full failover
      walk. Callers without a Keeper name keep the declared order. *)
type order =
  | Fixed
  | Spread_by_keeper
[@@deriving show, eq]

val order_to_string : order -> string
val order_of_string : string -> order option

type t =
  { id : string
  ; candidates : string list
  ; order : order
  }

val make : ?order:order -> id:string -> string list -> t
val id : t -> string
val order : t -> order
val ordered_candidates : t -> string list
val ordered_candidates_for : ?keeper_name:string -> t -> string list
