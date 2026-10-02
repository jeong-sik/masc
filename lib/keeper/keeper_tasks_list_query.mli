(** Explicit selection before task pagination. All supplied predicates are ANDed.
    Text search is literal, ASCII case-insensitive, over title and description;
    it does not infer relevance or change task state. *)
type t =
  { task_ids : string list option
  ; assignee : string option
  ; goal_id : string option
  ; query : string option
  }

val of_args : Yojson.Safe.t -> (t, string) result
val to_yojson : t -> Yojson.Safe.t
val equal : t -> t -> bool
val matches : t -> goal_task_ids:string list option -> Masc_domain.task -> bool
(** [goal_task_ids] comes from the authoritative Goal link registry when a
    Goal is selected. Registry read errors must be returned to the caller. *)
