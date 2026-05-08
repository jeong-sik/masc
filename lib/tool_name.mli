
(** Compile-time verified tool name identifiers.

    Use [of_string] at MCP/JSON parse boundaries only.
    All internal code passes [t] values directly. *)

module Keeper : sig
  type t =
    | Bash
    | Bash_kill
    | Bash_output
    | Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_curation_read
    | Board_curation_submit
    | Board_delete
    | Board_get
    | Board_list
    | Board_post
    | Board_search
    | Board_stats
    | Board_vote
    | Broadcast
    | Code_read
    | Context_status
    | Discovery
    | Fs_edit
    | Fs_read
    | Handoff
    | Library_read
    | Library_search
    | Memory_search
    | Memory_write
    | Pr_create
    | Pr_list
    | Pr_review_comment
    | Pr_review_read
    | Pr_review_reply
    | Pr_status
    | Preflight_check
    | Shell
    | Stay_silent
    | Task_claim
    | Task_create
    | Task_done
    | Task_submit_for_verification
    | Task_force_done
    | Task_force_release
    | Tasks_audit
    | Tasks_list
    | Time_now
    | Tool_search
    | Tools_list
    | Voice_agent
    | Voice_listen
    | Voice_session_end
    | Voice_session_start
    | Voice_sessions
    | Voice_speak
    | Write

  val to_string : t -> string
  val of_string : string -> t option
  val board_write_tools : t list
  val board_write_tool_names : string list
  val is_board : t -> bool
  val is_board_write : t -> bool
  val board_write_action_kind : t -> string option
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Masc : sig
  type t =
    | Add_task
    | Agent_fitness
    | Agent_update
    | Agent_card
    | Agents
    | Autoresearch_cycle
    | Autoresearch_inject
    | Autoresearch_record_finding
    | Autoresearch_search_findings
    | Autoresearch_start
    | Autoresearch_status
    | Autoresearch_stop
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
    | Board_vote
    | Broadcast
    | Cancel_task
    | Check
    | Claim_next
    | Claim_task
    | Cleanup_zombies
    | Coordination_fsm_snapshot
    | Code_delete
    | Code_edit
    | Code_git
    | Code_read
    | Code_search
    | Code_shell
    | Code_symbols
    | Code_write
    | Complete_task
    | Dashboard
    | Deliver
    | Dispatch_plan
    | Goal_list
    | Goal_review
    | Goal_transition
    | Goal_upsert
    | Goal_verify
    | Heartbeat
    | Join
    | Leave
    | List_tasks
    | Messages
    | Note_add
    | Operation_pause
    | Operation_start
    | Operation_status
    | Operation_stop
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
    | Register_capabilities
    | Release_task
    | Reset
    | Coord_status
    | Set_current_task
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
    | Who
    | Workflow_guide
    | Worktree_create
    | Worktree_list
    | Worktree_remove
    | Approval_pending
    | Approval_get
    | Config
    | Gc
    | Get_metrics
    | Mcp_session
    | Pause
    | Resume
    | Spawn
    | Start
    | Tool_admin_snapshot
    | Tool_admin_update
    | Tool_stats
    | Webrtc_answer
    | Webrtc_offer

  val to_string : t -> string
  val of_string : string -> t option
  val is_board : t -> bool
  val pp : Stdlib.Format.formatter -> t -> unit
end

module Masc_keeper : sig
  type t =
    | Clear
    | Compact
    | Create_from_persona
    | Down
    | List
    | Msg
    | Persona_audit
    | Repair
    | Reset
    | Status
    | Up

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Stdlib.Format.formatter -> t -> unit
end

type t =
  | Keeper of Keeper.t
  | Masc of Masc.t
  | Masc_keeper of Masc_keeper.t

val to_string : t -> string
val of_string : string -> t option
val pp : Stdlib.Format.formatter -> t -> unit

val is_keeper : t -> bool
val is_masc : t -> bool
val is_masc_keeper : t -> bool
val is_board : t -> bool
