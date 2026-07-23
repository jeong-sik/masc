(** Typed filename authority for regular files directly under
    [.masc/keepers].  High-cardinality lane artifacts belong below the Keeper
    directory; these constructors are the closed set of legacy/current root
    artifacts that runtime producers still own. *)

type keeper_artifact =
  | Metadata
  | Memory_log
  | Generation_index_log
  | Decision_log
  | Feedback_log
  | Tla_trace_log

type t =
  | Keeper of
      { keeper_name : string
      ; artifact : keeper_artifact
      ; rotation : int option
      }

val keeper_basename : keeper_name:string -> keeper_artifact -> string
val basename : t -> string

(** Return every typed interpretation whose canonical renderer exactly
    round-trips to the input. The root catalog is injective; the list shape
    makes that invariant directly testable without a hidden descriptor-order
    fallback. *)
val classify_basename : string -> t list

(** Exact metadata interpretation, independent of overlapping artifact
    suffixes. *)
val metadata_keeper_name : string -> string option
