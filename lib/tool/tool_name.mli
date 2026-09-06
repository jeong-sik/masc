(** Tool-name vocabularies, one closed type per domain.

    Each submodule owns the complete [masc_*] string for its operations, with
    [all] exhaustive and [of_string] derived from it.

    Routing parses the wire string once with the owning domain's [of_string]
    and matches the constructors, so a constructor added here is a compile
    error at the site that handles it. Non-domain [masc_*] names are owned by
    their schema/descriptor modules, not by this substrate. *)

module Task_name : sig
  type t =
    | Add_task
    | Batch_add_tasks
    | Task_history
    | Task_set_goal
    | Tasks
    | Transition
    | Update_priority

  val all : t list
  (** Exhaustive Task operation vocabulary. *)

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Board_name : sig
  type t =
    | Board_post
    | Board_post_update
    | Board_list
    | Board_post_get
    | Board_comment
    | Board_vote
    | Board_stats
    | Board_search
    | Board_comment_vote
    | Board_reaction
    | Board_profile
    | Board_hearths
    | Board_curation_read
    | Board_curation_submit
    | Board_delete
    | Board_cleanup
    | Board_sub_board_create
    | Board_sub_board_list
    | Board_sub_board_get
    | Board_sub_board_update
    | Board_sub_board_delete

  val all : t list
  (** Exhaustive Board operation vocabulary in stable advertised order. *)

  val operation_name : t -> string
  (** Stable operation token without the [masc_board_] transport prefix. *)

  val to_string : t -> string
  val of_string : string -> t option
  val is_resource_write : t -> bool
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Goal_name : sig
  type t =
    | Goal_list
    | Goal_transition
    | Goal_upsert

  val all : t list
  (** Exhaustive Goal operation vocabulary. *)

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Operator_name : sig
  type t =
    | Operator_action
    | Operator_board_attention_quarantine_requeue
    | Operator_confirm
    | Operator_digest
    | Operator_judgment_write
    | Operator_snapshot
    | Operator_task_recovery_resolve

  val all : t list
  (** Exhaustive Operator operation vocabulary. *)

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Operator_remote_name : sig
  type t = Operator_tool of Operator_name.t

  val to_string : t -> string
  val of_string : string -> t option
  val all : t list
  val all_strings : string list
  val pp : Stdlib.Format.formatter -> t -> unit
end
