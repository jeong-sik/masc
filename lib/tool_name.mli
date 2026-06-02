(** Compile-time verified tool name identifiers.

    Use [of_string] at MCP/JSON parse boundaries only.
    All internal code passes [t] values directly. *)

module Masc : sig
  type t =
    | Add_task
    | Agent_fitness
    | Agent_update
    | Agent_card
    | Agents
    | Batch_add_tasks
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
    | Broadcast
    | Check
    | Claim_next
    | Cleanup_zombies
    | Dashboard
    | Deliver
    | Goal_list
    | Goal_transition
    | Goal_upsert
    | Goal_verify
    | Heartbeat
    | Messages
    | Note_add
    | Operator_action
    | Operator_confirm
    | Operator_digest
    | Operator_snapshot
    | Plan_clear_task
    | Plan_get
    | Plan_get_task
    | Plan_init
    | Plan_set_task
    | Plan_update
    | Reset
    | Status
    | Task_history
    | Tasks
    | Tool_grant
    | Tool_help
    | Tool_list
    | Tool_revoke
    | Transition
    | Update_priority
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
