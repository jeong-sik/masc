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
    | Pr_review_comment
    | Pr_review_read
    | Pr_review_reply
    | Preflight_check
    | Shell
    | Stay_silent
    | Task_claim
    | Task_create
    | Task_done
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
  val pp : Format.formatter -> t -> unit
end

module Masc : sig
  type t =
    | A2a_delegate
    | Add_task
    | Agent_card
    | Agent_fitness
    | Agent_update
    | Agents
    | Autoresearch_cycle
    | Autoresearch_inject
    | Autoresearch_start
    | Autoresearch_status
    | Autoresearch_stop
    | Batch_add_tasks
    | Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_delete
    | Board_get
    | Board_hearths
    | Board_list
    | Board_post
    | Board_profile
    | Board_search
    | Board_stats
    | Board_vote
    | Broadcast
    | Cancel_task
    | Check
    | Claim_next
    | Claim_task
    | Cleanup_zombies
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
    | Dispatch_assign
    | Dispatch_plan
    | Goal_list
    | Goal_review
    | Goal_transition
    | Goal_upsert
    | Goal_verify
    | Find_by_capability
    | Governance_feed
    | Governance_status
    | Heartbeat
    | Join
    | Leave
    | List_tasks
    | Messages
    | Note_add
    | Operation_checkpoint
    | Operation_finalize
    | Operation_pause
    | Operation_resume
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
    | Web_search
    | Who
    | Workflow_guide
    | Worktree_create
    | Worktree_list
    | Worktree_remove
    | Worktree_status

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Format.formatter -> t -> unit
end

module Masc_keeper : sig
  type t =
    | Clear
    | Compact
    | Create_from_persona
    | Down
    | List
    | Msg
    | Repair
    | Reset
    | Status
    | Up

  val to_string : t -> string
  val of_string : string -> t option
  val pp : Format.formatter -> t -> unit
end

type t =
  | Keeper of Keeper.t
  | Masc of Masc.t
  | Masc_keeper of Masc_keeper.t

val to_string : t -> string
val of_string : string -> t option
val pp : Format.formatter -> t -> unit

val is_keeper : t -> bool
val is_masc : t -> bool
val is_masc_keeper : t -> bool
