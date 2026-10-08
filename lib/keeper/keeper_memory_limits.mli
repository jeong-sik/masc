(** Count-based ordinary Memory working-set targets. Custom and built-in
    categories occupy the same slots. Archived and source-bound claims are
    outside this category-bearing current store. Nothing is evicted here. *)

type t =
  { category_cap : int
  ; facts_per_category_cap : int
  ; category_counts : (string * int) list
  }

val measure :
  category_cap:int ->
  facts_per_category_cap:int ->
  Keeper_memory_os_types.fact list -> t

val current : Keeper_memory_os_types.fact list -> t
(** Measure with the operator's effective TOML/env settings. *)

val exceeded : t -> bool

val excess_reduced : before:t -> after:t -> bool
(** Compare occupied-category excess and the sum of per-category item excess
    separately. At least one must fall and neither may rise. Both reports must
    use the same operator limits; a settings change is not cleanup progress. *)

val to_json : t -> Yojson.Safe.t
(** Includes every occupied category and its excess, total occupied category
    count, and category excess. Limits are advisory during the initial rollout. *)
