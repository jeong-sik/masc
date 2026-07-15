(** Compile-time verified tool name identifiers.

    Use [of_string] at MCP/JSON parse boundaries only.
    All internal code passes [t] values directly.

    PR-S1: domain tool *names* (Task/Board/Operator) are owned by the
    submodules below; [Masc.t] composes them. Each submodule owns the complete
    [masc_*] string for its operations. *)

module Task_name : sig
  type t =
    | Add_task
    | Batch_add_tasks
    | Task_history
    | Tasks
    | Transition
    | Update_priority

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

module Operator_name : sig
  type t =
    | Operator_action
    | Operator_chat_recovery_resolve
    | Operator_confirm
    | Operator_digest
    | Operator_snapshot

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

(** Domain_tool — single domain-owned grouping of Task/Board/Operator tool
    names. This module owns only names and string round-tripping; dispatch and
    execution decisions belong to their explicit boundaries. *)
module Domain_tool : sig
  type t =
    | Task of Task_name.t
    | Board of Board_name.t
    | Operator of Operator_name.t

  val to_string : t -> string
  val of_string : string -> t option
  val is_board : t -> bool
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Masc : sig
  type t =
    | Domain of Domain_tool.t

  val to_string : t -> string
  val of_string : string -> t option
  val is_board : t -> bool
  val pp : Stdlib.Format.formatter -> t -> unit
end

type t =
  | Masc of Masc.t

val to_string : t -> string
val of_string : string -> t option
val pp : Stdlib.Format.formatter -> t -> unit
val is_masc : t -> bool
val is_board : t -> bool
