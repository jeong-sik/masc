(** Compile-time verified tool name identifiers.

    Use [of_string] at MCP/JSON parse boundaries only.
    All internal code passes [t] values directly.

    PR-S1: domain tool *names* (Task/Board/Goal/Operator) are owned by the
    submodules below; [Masc.t] composes them. Each submodule owns the complete
    [masc_*] string for its operations. *)

module Task_name : sig
  type t =
    | Add_task
    | Batch_add_tasks
    | Claim_next
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
    | Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_curation_read
    | Board_curation_submit
    | Board_delete
    | Board_get
    | Board_hearths
    | Board_list
    | Board_post
    | Board_profile
    | Board_reaction
    | Board_search
    | Board_stats
    | Board_sub_board_create
    | Board_sub_board_delete
    | Board_sub_board_get
    | Board_sub_board_list
    | Board_sub_board_update
    | Board_vote

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Goal_name : sig
  type t =
    | Goal_list
    | Goal_transition
    | Goal_upsert
    | Goal_verify

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Operator_name : sig
  type t =
    | Operator_action
    | Operator_confirm
    | Operator_digest
    | Operator_snapshot

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Stdlib.Format.formatter -> t -> unit
end

(** Domain_tool — single domain-owned grouping of Task/Board/Goal/Operator tool
    names plus the substrate classifications ([module_tag]/[effect_domain]) each
    domain attaches. This is the only module that enumerates the domain
    constructors; the substrate consumes it through these functions without
    spelling any domain constructor. *)
module Domain_tool : sig
  type t =
    | Task of Task_name.t
    | Board of Board_name.t
    | Goal of Goal_name.t
    | Operator of Operator_name.t

  val to_string : t -> string
  val of_string : string -> t option
  val is_board : t -> bool
  val module_tag : t -> Tool_tag_types.module_tag
  val effect_domain : t -> Tool_tag_types.effect_domain
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Masc : sig
  type t =
    | Domain of Domain_tool.t
    | Agent_fitness
    | Agent_update
    | Agent_card
    | Agents
    | Broadcast
    | Check
    | Cleanup_zombies
    | Dashboard
    | Deliver
    | Heartbeat
    | Messages
    | Note_add
    | Plan_clear_task
    | Plan_get
    | Plan_get_task
    | Plan_init
    | Plan_set_task
    | Plan_update
    | Reset
    | Status
    | Tool_grant
    | Tool_help
    | Tool_list
    | Tool_revoke
    | Web_fetch
    | Web_search
    | Approval_pending
    | Approval_get
    | Config
    | Gc
    | Get_metrics
    | Mcp_session
    | Pause
    | Resume
    | Start
    | Tool_admin_snapshot
    | Tool_admin_update
    | Tool_stats

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
