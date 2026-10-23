(** The owner of an input, stated before dispatch. A missing trace never
    selects a completion-review policy. *)
type t =
  | Keeper_history of { trace_id : string }
  | Completion_review

val trace_id : t -> string option
(** [None] only for program-owned completion evidence, which has no durable
    Keeper history or Librarian boundary. *)
