(** Typed filename authority for regular files directly under
    [.masc/keepers]. High-cardinality lane artifacts belong below the Keeper
    directory; these constructors are the closed set of root artifacts that
    current runtime producers own. *)

type keeper_artifact =
  | Metadata
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

(** Exact metadata interpretation, independent of overlapping artifact
    suffixes. *)
val metadata_keeper_name : string -> string option
