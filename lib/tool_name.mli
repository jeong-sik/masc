(** Compile-time verified tool name identifiers.

    Use [of_string] at MCP/JSON parse boundaries only.
    All internal code passes [t] values directly. *)

module Keeper : sig
  type t =
    | Bash
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
    | Pr_submit
    | Pr_workflow
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
    | Find_by_capability
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
    | Room_status
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
    | Autoresearch_swarm_start
    | Collaboration_graph
    | Config
    | Dispatch_escalate
    | Dispatch_rebalance
    | Dispatch_recall
    | Done
    | Get_metrics
    | Keeper_msg_result
    | Observe_alerts
    | Observe_capacity
    | Observe_operations
    | Observe_swarm
    | Observe_topology
    | Observe_traces
    | Policy_approve
    | Policy_deny
    | Policy_status
    | Policy_update
    | Portal_close
    | Portal_open
    | Portal_send
    | Release
    | Runtime_ollama_probe
    | Runtime_verify
    | Surface_audit
    | Tool_admin_snapshot
    | Tool_admin_update
    | Tool_stats
    | Unit_define
    | Unit_list
    | Unit_reassign
    | Unit_reparent
    | Webrtc_answer
    | Webrtc_offer
    | Admin_cleanup
    | Admin_reset
    | Agent_timeline
    | Execute
    | Execute_dry_run
    | Force_leave
    | Gc
    | Gc_force
    | Library_add
    | Library_list
    | Library_promote
    | Library_read
    | Library_search
    | Listen
    | Mcp_session
    | Operator_judgment_write
    | Pause
    | Persona_list
    | Recall_search
    | Resume
    | Room_delete
    | Run_deliverable
    | Run_get
    | Run_init
    | Run_list
    | Run_log
    | Run_plan
    | Set_param
    | Set_room
    | Spawn
    | Start
    | Verify_auto
    | Verify_pending
    | Verify_request
    | Verify_status
    | Verify_submit
    | Voice_ping_pong

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

(** Infrastructure-level tools with no keeper_*/masc_* prefix. *)
type infra =
  | Channel_gate

val infra_to_string : infra -> string
val infra_of_string : string -> infra option

type t =
  | Keeper of Keeper.t
  | Masc of Masc.t
  | Masc_keeper of Masc_keeper.t
  | Infra of infra

val to_string : t -> string
val of_string : string -> t option
val pp : Format.formatter -> t -> unit

val is_keeper : t -> bool
val is_masc : t -> bool
val is_masc_keeper : t -> bool
