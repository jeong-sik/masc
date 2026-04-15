(** Tool_name — Compile-time verified tool identifiers.

    Replaces stringly-typed tool dispatch with exhaustive variant matching.
    Parse boundary: [of_string] at MCP/JSON ingress only.
    Internal code uses [t] directly — typos become compile errors. *)

module Keeper = struct
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

  let to_string = function
    | Bash -> "keeper_bash"
    | Board_cleanup -> "keeper_board_cleanup"
    | Board_comment -> "keeper_board_comment"
    | Board_comment_vote -> "keeper_board_comment_vote"
    | Board_delete -> "keeper_board_delete"
    | Board_get -> "keeper_board_get"
    | Board_list -> "keeper_board_list"
    | Board_post -> "keeper_board_post"
    | Board_search -> "keeper_board_search"
    | Board_stats -> "keeper_board_stats"
    | Board_vote -> "keeper_board_vote"
    | Broadcast -> "keeper_broadcast"
    | Code_read -> "keeper_code_read"
    | Context_status -> "keeper_context_status"
    | Discovery -> "keeper_discovery"
    | Fs_edit -> "keeper_fs_edit"
    | Fs_read -> "keeper_fs_read"
    | Handoff -> "keeper_handoff"
    | Library_read -> "keeper_library_read"
    | Library_search -> "keeper_library_search"
    | Memory_search -> "keeper_memory_search"
    | Pr_review_comment -> "keeper_pr_review_comment"
    | Pr_review_read -> "keeper_pr_review_read"
    | Pr_review_reply -> "keeper_pr_review_reply"
    | Pr_submit -> "keeper_pr_submit"
    | Pr_workflow -> "keeper_pr_workflow"
    | Preflight_check -> "keeper_preflight_check"
    | Shell -> "keeper_shell"
    | Stay_silent -> "keeper_stay_silent"
    | Task_claim -> "keeper_task_claim"
    | Task_create -> "keeper_task_create"
    | Task_done -> "keeper_task_done"
    | Task_force_done -> "keeper_task_force_done"
    | Task_force_release -> "keeper_task_force_release"
    | Tasks_audit -> "keeper_tasks_audit"
    | Tasks_list -> "keeper_tasks_list"
    | Time_now -> "keeper_time_now"
    | Tool_search -> "keeper_tool_search"
    | Tools_list -> "keeper_tools_list"
    | Voice_agent -> "keeper_voice_agent"
    | Voice_listen -> "keeper_voice_listen"
    | Voice_session_end -> "keeper_voice_session_end"
    | Voice_session_start -> "keeper_voice_session_start"
    | Voice_sessions -> "keeper_voice_sessions"
    | Voice_speak -> "keeper_voice_speak"

  let of_string = function
    | "keeper_bash" -> Some Bash
    | "keeper_board_cleanup" -> Some Board_cleanup
    | "keeper_board_comment" -> Some Board_comment
    | "keeper_board_comment_vote" -> Some Board_comment_vote
    | "keeper_board_delete" -> Some Board_delete
    | "keeper_board_get" -> Some Board_get
    | "keeper_board_list" -> Some Board_list
    | "keeper_board_post" -> Some Board_post
    | "keeper_board_search" -> Some Board_search
    | "keeper_board_stats" -> Some Board_stats
    | "keeper_board_vote" -> Some Board_vote
    | "keeper_broadcast" -> Some Broadcast
    | "keeper_code_read" -> Some Code_read
    | "keeper_context_status" -> Some Context_status
    | "keeper_discovery" -> Some Discovery
    | "keeper_fs_edit" -> Some Fs_edit
    | "keeper_fs_read" -> Some Fs_read
    | "keeper_handoff" -> Some Handoff
    | "keeper_library_read" -> Some Library_read
    | "keeper_library_search" -> Some Library_search
    | "keeper_memory_search" -> Some Memory_search
    | "keeper_pr_review_comment" -> Some Pr_review_comment
    | "keeper_pr_review_read" -> Some Pr_review_read
    | "keeper_pr_review_reply" -> Some Pr_review_reply
    | "keeper_pr_submit" -> Some Pr_submit
    | "keeper_pr_workflow" -> Some Pr_workflow
    | "keeper_preflight_check" -> Some Preflight_check
    | "keeper_shell" -> Some Shell
    | "keeper_stay_silent" -> Some Stay_silent
    | "keeper_task_claim" -> Some Task_claim
    | "keeper_task_create" -> Some Task_create
    | "keeper_task_done" -> Some Task_done
    | "keeper_task_force_done" -> Some Task_force_done
    | "keeper_task_force_release" -> Some Task_force_release
    | "keeper_tasks_audit" -> Some Tasks_audit
    | "keeper_tasks_list" -> Some Tasks_list
    | "keeper_time_now" -> Some Time_now
    | "keeper_tool_search" -> Some Tool_search
    | "keeper_tools_list" -> Some Tools_list
    | "keeper_voice_agent" -> Some Voice_agent
    | "keeper_voice_listen" -> Some Voice_listen
    | "keeper_voice_session_end" -> Some Voice_session_end
    | "keeper_voice_session_start" -> Some Voice_session_start
    | "keeper_voice_sessions" -> Some Voice_sessions
    | "keeper_voice_speak" -> Some Voice_speak
    | _ -> None

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Masc = struct
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
    (* Expanded coverage for tool_permission_map.ml *)
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
    (* Admin / lifecycle tools *)
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

  let to_string = function
    | A2a_delegate -> "masc_a2a_delegate"
    | Add_task -> "masc_add_task"
    | Agent_card -> "masc_agent_card"
    | Agent_fitness -> "masc_agent_fitness"
    | Agent_update -> "masc_agent_update"
    | Agents -> "masc_agents"
    | Batch_add_tasks -> "masc_batch_add_tasks"
    | Board_cleanup -> "masc_board_cleanup"
    | Board_comment -> "masc_board_comment"
    | Board_comment_vote -> "masc_board_comment_vote"
    | Board_delete -> "masc_board_delete"
    | Board_get -> "masc_board_get"
    | Board_hearths -> "masc_board_hearths"
    | Board_list -> "masc_board_list"
    | Board_post -> "masc_board_post"
    | Board_profile -> "masc_board_profile"
    | Board_search -> "masc_board_search"
    | Board_stats -> "masc_board_stats"
    | Board_vote -> "masc_board_vote"
    | Broadcast -> "masc_broadcast"
    | Cancel_task -> "masc_cancel_task"
    | Check -> "masc_check"
    | Claim_next -> "masc_claim_next"
    | Claim_task -> "masc_claim_task"
    | Cleanup_zombies -> "masc_cleanup_zombies"
    | Autoresearch_cycle -> "masc_autoresearch_cycle"
    | Autoresearch_inject -> "masc_autoresearch_inject"
    | Autoresearch_start -> "masc_autoresearch_start"
    | Autoresearch_status -> "masc_autoresearch_status"
    | Autoresearch_stop -> "masc_autoresearch_stop"
    | Code_delete -> "masc_code_delete"
    | Code_edit -> "masc_code_edit"
    | Code_git -> "masc_code_git"
    | Code_read -> "masc_code_read"
    | Code_search -> "masc_code_search"
    | Code_shell -> "masc_code_shell"
    | Code_symbols -> "masc_code_symbols"
    | Code_write -> "masc_code_write"
    | Complete_task -> "masc_complete_task"
    | Dashboard -> "masc_dashboard"
    | Deliver -> "masc_deliver"
    | Dispatch_assign -> "masc_dispatch_assign"
    | Dispatch_plan -> "masc_dispatch_plan"
    | Find_by_capability -> "masc_find_by_capability"
    | Heartbeat -> "masc_heartbeat"
    | Join -> "masc_join"
    | Leave -> "masc_leave"
    | List_tasks -> "masc_list_tasks"
    | Messages -> "masc_messages"
    | Note_add -> "masc_note_add"
    | Operation_checkpoint -> "masc_operation_checkpoint"
    | Operation_finalize -> "masc_operation_finalize"
    | Operation_pause -> "masc_operation_pause"
    | Operation_resume -> "masc_operation_resume"
    | Operation_start -> "masc_operation_start"
    | Operation_status -> "masc_operation_status"
    | Operation_stop -> "masc_operation_stop"
    | Operator_action -> "masc_operator_action"
    | Operator_confirm -> "masc_operator_confirm"
    | Operator_digest -> "masc_operator_digest"
    | Operator_snapshot -> "masc_operator_snapshot"
    | Plan_clear_task -> "masc_plan_clear_task"
    | Plan_get -> "masc_plan_get"
    | Plan_get_task -> "masc_plan_get_task"
    | Plan_init -> "masc_plan_init"
    | Plan_set_task -> "masc_plan_set_task"
    | Plan_update -> "masc_plan_update"
    | Register_capabilities -> "masc_register_capabilities"
    | Release_task -> "masc_release_task"
    | Reset -> "masc_reset"
    | Room_status -> "masc_room_status"
    | Set_current_task -> "masc_set_current_task"
    | Status -> "masc_status"
    | Task_history -> "masc_task_history"
    | Tasks -> "masc_tasks"
    | Tool_grant -> "masc_tool_grant"
    | Tool_help -> "masc_tool_help"
    | Tool_list -> "masc_tool_list"
    | Tool_revoke -> "masc_tool_revoke"
    | Transition -> "masc_transition"
    | Update_priority -> "masc_update_priority"
    | Web_search -> "masc_web_search"
    | Who -> "masc_who"
    | Workflow_guide -> "masc_workflow_guide"
    | Worktree_create -> "masc_worktree_create"
    | Worktree_list -> "masc_worktree_list"
    | Worktree_remove -> "masc_worktree_remove"
    | Worktree_status -> "masc_worktree_status"
    | Autoresearch_swarm_start -> "masc_autoresearch_swarm_start"
    | Collaboration_graph -> "masc_collaboration_graph"
    | Config -> "masc_config"
    | Dispatch_escalate -> "masc_dispatch_escalate"
    | Dispatch_rebalance -> "masc_dispatch_rebalance"
    | Dispatch_recall -> "masc_dispatch_recall"
    | Done -> "masc_done"
    | Get_metrics -> "masc_get_metrics"
    | Keeper_msg_result -> "masc_keeper_msg_result"
    | Observe_alerts -> "masc_observe_alerts"
    | Observe_capacity -> "masc_observe_capacity"
    | Observe_operations -> "masc_observe_operations"
    | Observe_swarm -> "masc_observe_swarm"
    | Observe_topology -> "masc_observe_topology"
    | Observe_traces -> "masc_observe_traces"
    | Policy_approve -> "masc_policy_approve"
    | Policy_deny -> "masc_policy_deny"
    | Policy_status -> "masc_policy_status"
    | Policy_update -> "masc_policy_update"
    | Portal_close -> "masc_portal_close"
    | Portal_open -> "masc_portal_open"
    | Portal_send -> "masc_portal_send"
    | Release -> "masc_release"
    | Runtime_ollama_probe -> "masc_runtime_ollama_probe"
    | Runtime_verify -> "masc_runtime_verify"
    | Surface_audit -> "masc_surface_audit"
    | Tool_admin_snapshot -> "masc_tool_admin_snapshot"
    | Tool_admin_update -> "masc_tool_admin_update"
    | Tool_stats -> "masc_tool_stats"
    | Unit_define -> "masc_unit_define"
    | Unit_list -> "masc_unit_list"
    | Unit_reassign -> "masc_unit_reassign"
    | Unit_reparent -> "masc_unit_reparent"
    | Webrtc_answer -> "masc_webrtc_answer"
    | Webrtc_offer -> "masc_webrtc_offer"
    | Admin_cleanup -> "masc_admin_cleanup"
    | Admin_reset -> "masc_admin_reset"
    | Agent_timeline -> "masc_agent_timeline"
    | Execute -> "masc_execute"
    | Execute_dry_run -> "masc_execute_dry_run"
    | Force_leave -> "masc_force_leave"
    | Gc -> "masc_gc"
    | Gc_force -> "masc_gc_force"
    | Library_add -> "masc_library_add"
    | Library_list -> "masc_library_list"
    | Library_promote -> "masc_library_promote"
    | Library_read -> "masc_library_read"
    | Library_search -> "masc_library_search"
    | Listen -> "masc_listen"
    | Mcp_session -> "masc_mcp_session"
    | Operator_judgment_write -> "masc_operator_judgment_write"
    | Pause -> "masc_pause"
    | Persona_list -> "masc_persona_list"
    | Recall_search -> "masc_recall_search"
    | Resume -> "masc_resume"
    | Room_delete -> "masc_room_delete"
    | Run_deliverable -> "masc_run_deliverable"
    | Run_get -> "masc_run_get"
    | Run_init -> "masc_run_init"
    | Run_list -> "masc_run_list"
    | Run_log -> "masc_run_log"
    | Run_plan -> "masc_run_plan"
    | Set_param -> "masc_set_param"
    | Set_room -> "masc_set_room"
    | Spawn -> "masc_spawn"
    | Start -> "masc_start"
    | Verify_auto -> "masc_verify_auto"
    | Verify_pending -> "masc_verify_pending"
    | Verify_request -> "masc_verify_request"
    | Verify_status -> "masc_verify_status"
    | Verify_submit -> "masc_verify_submit"
    | Voice_ping_pong -> "masc_voice_ping_pong"

  let of_string = function
    | "masc_a2a_delegate" -> Some A2a_delegate
    | "masc_add_task" -> Some Add_task
    | "masc_agent_card" -> Some Agent_card
    | "masc_agent_fitness" -> Some Agent_fitness
    | "masc_agent_update" -> Some Agent_update
    | "masc_agents" -> Some Agents
    | "masc_batch_add_tasks" -> Some Batch_add_tasks
    | "masc_board_cleanup" -> Some Board_cleanup
    | "masc_board_comment" -> Some Board_comment
    | "masc_board_comment_vote" -> Some Board_comment_vote
    | "masc_board_delete" -> Some Board_delete
    | "masc_board_get" -> Some Board_get
    | "masc_board_hearths" -> Some Board_hearths
    | "masc_board_list" -> Some Board_list
    | "masc_board_post" -> Some Board_post
    | "masc_board_profile" -> Some Board_profile
    | "masc_board_search" -> Some Board_search
    | "masc_board_stats" -> Some Board_stats
    | "masc_board_vote" -> Some Board_vote
    | "masc_broadcast" -> Some Broadcast
    | "masc_cancel_task" -> Some Cancel_task
    | "masc_check" -> Some Check
    | "masc_claim_next" -> Some Claim_next
    | "masc_claim_task" -> Some Claim_task
    | "masc_cleanup_zombies" -> Some Cleanup_zombies
    | "masc_autoresearch_cycle" -> Some Autoresearch_cycle
    | "masc_autoresearch_inject" -> Some Autoresearch_inject
    | "masc_autoresearch_start" -> Some Autoresearch_start
    | "masc_autoresearch_status" -> Some Autoresearch_status
    | "masc_autoresearch_stop" -> Some Autoresearch_stop
    | "masc_code_delete" -> Some Code_delete
    | "masc_code_edit" -> Some Code_edit
    | "masc_code_git" -> Some Code_git
    | "masc_code_read" -> Some Code_read
    | "masc_code_search" -> Some Code_search
    | "masc_code_shell" -> Some Code_shell
    | "masc_code_symbols" -> Some Code_symbols
    | "masc_code_write" -> Some Code_write
    | "masc_complete_task" -> Some Complete_task
    | "masc_dashboard" -> Some Dashboard
    | "masc_deliver" -> Some Deliver
    | "masc_dispatch_assign" -> Some Dispatch_assign
    | "masc_dispatch_plan" -> Some Dispatch_plan
    | "masc_find_by_capability" -> Some Find_by_capability
    | "masc_heartbeat" -> Some Heartbeat
    | "masc_join" -> Some Join
    | "masc_leave" -> Some Leave
    | "masc_list_tasks" -> Some List_tasks
    | "masc_messages" -> Some Messages
    | "masc_note_add" -> Some Note_add
    | "masc_operation_checkpoint" -> Some Operation_checkpoint
    | "masc_operation_finalize" -> Some Operation_finalize
    | "masc_operation_pause" -> Some Operation_pause
    | "masc_operation_resume" -> Some Operation_resume
    | "masc_operation_start" -> Some Operation_start
    | "masc_operation_status" -> Some Operation_status
    | "masc_operation_stop" -> Some Operation_stop
    | "masc_operator_action" -> Some Operator_action
    | "masc_operator_confirm" -> Some Operator_confirm
    | "masc_operator_digest" -> Some Operator_digest
    | "masc_operator_snapshot" -> Some Operator_snapshot
    | "masc_plan_clear_task" -> Some Plan_clear_task
    | "masc_plan_get" -> Some Plan_get
    | "masc_plan_get_task" -> Some Plan_get_task
    | "masc_plan_init" -> Some Plan_init
    | "masc_plan_set_task" -> Some Plan_set_task
    | "masc_plan_update" -> Some Plan_update
    | "masc_register_capabilities" -> Some Register_capabilities
    | "masc_release_task" -> Some Release_task
    | "masc_reset" -> Some Reset
    | "masc_room_status" -> Some Room_status
    | "masc_set_current_task" -> Some Set_current_task
    | "masc_status" -> Some Status
    | "masc_task_history" -> Some Task_history
    | "masc_tasks" -> Some Tasks
    | "masc_tool_grant" -> Some Tool_grant
    | "masc_tool_help" -> Some Tool_help
    | "masc_tool_list" -> Some Tool_list
    | "masc_tool_revoke" -> Some Tool_revoke
    | "masc_transition" -> Some Transition
    | "masc_update_priority" -> Some Update_priority
    | "masc_web_search" -> Some Web_search
    | "masc_who" -> Some Who
    | "masc_workflow_guide" -> Some Workflow_guide
    | "masc_worktree_create" -> Some Worktree_create
    | "masc_worktree_list" -> Some Worktree_list
    | "masc_worktree_remove" -> Some Worktree_remove
    | "masc_worktree_status" -> Some Worktree_status
    | "masc_autoresearch_swarm_start" -> Some Autoresearch_swarm_start
    | "masc_collaboration_graph" -> Some Collaboration_graph
    | "masc_config" -> Some Config
    | "masc_dispatch_escalate" -> Some Dispatch_escalate
    | "masc_dispatch_rebalance" -> Some Dispatch_rebalance
    | "masc_dispatch_recall" -> Some Dispatch_recall
    | "masc_done" -> Some Done
    | "masc_get_metrics" -> Some Get_metrics
    | "masc_keeper_msg_result" -> Some Keeper_msg_result
    | "masc_observe_alerts" -> Some Observe_alerts
    | "masc_observe_capacity" -> Some Observe_capacity
    | "masc_observe_operations" -> Some Observe_operations
    | "masc_observe_swarm" -> Some Observe_swarm
    | "masc_observe_topology" -> Some Observe_topology
    | "masc_observe_traces" -> Some Observe_traces
    | "masc_policy_approve" -> Some Policy_approve
    | "masc_policy_deny" -> Some Policy_deny
    | "masc_policy_status" -> Some Policy_status
    | "masc_policy_update" -> Some Policy_update
    | "masc_portal_close" -> Some Portal_close
    | "masc_portal_open" -> Some Portal_open
    | "masc_portal_send" -> Some Portal_send
    | "masc_release" -> Some Release
    | "masc_runtime_ollama_probe" -> Some Runtime_ollama_probe
    | "masc_runtime_verify" -> Some Runtime_verify
    | "masc_surface_audit" -> Some Surface_audit
    | "masc_tool_admin_snapshot" -> Some Tool_admin_snapshot
    | "masc_tool_admin_update" -> Some Tool_admin_update
    | "masc_tool_stats" -> Some Tool_stats
    | "masc_unit_define" -> Some Unit_define
    | "masc_unit_list" -> Some Unit_list
    | "masc_unit_reassign" -> Some Unit_reassign
    | "masc_unit_reparent" -> Some Unit_reparent
    | "masc_webrtc_answer" -> Some Webrtc_answer
    | "masc_webrtc_offer" -> Some Webrtc_offer
    | "masc_admin_cleanup" -> Some Admin_cleanup
    | "masc_admin_reset" -> Some Admin_reset
    | "masc_agent_timeline" -> Some Agent_timeline
    | "masc_execute" -> Some Execute
    | "masc_execute_dry_run" -> Some Execute_dry_run
    | "masc_force_leave" -> Some Force_leave
    | "masc_gc" -> Some Gc
    | "masc_gc_force" -> Some Gc_force
    | "masc_library_add" -> Some Library_add
    | "masc_library_list" -> Some Library_list
    | "masc_library_promote" -> Some Library_promote
    | "masc_library_read" -> Some Library_read
    | "masc_library_search" -> Some Library_search
    | "masc_listen" -> Some Listen
    | "masc_mcp_session" -> Some Mcp_session
    | "masc_operator_judgment_write" -> Some Operator_judgment_write
    | "masc_pause" -> Some Pause
    | "masc_persona_list" -> Some Persona_list
    | "masc_recall_search" -> Some Recall_search
    | "masc_resume" -> Some Resume
    | "masc_room_delete" -> Some Room_delete
    | "masc_run_deliverable" -> Some Run_deliverable
    | "masc_run_get" -> Some Run_get
    | "masc_run_init" -> Some Run_init
    | "masc_run_list" -> Some Run_list
    | "masc_run_log" -> Some Run_log
    | "masc_run_plan" -> Some Run_plan
    | "masc_set_param" -> Some Set_param
    | "masc_set_room" -> Some Set_room
    | "masc_spawn" -> Some Spawn
    | "masc_start" -> Some Start
    | "masc_verify_auto" -> Some Verify_auto
    | "masc_verify_pending" -> Some Verify_pending
    | "masc_verify_request" -> Some Verify_request
    | "masc_verify_status" -> Some Verify_status
    | "masc_verify_submit" -> Some Verify_submit
    | "masc_voice_ping_pong" -> Some Voice_ping_pong
    | _ -> None

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Masc_keeper = struct
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

  let to_string = function
    | Clear -> "masc_keeper_clear"
    | Compact -> "masc_keeper_compact"
    | Create_from_persona -> "masc_keeper_create_from_persona"
    | Down -> "masc_keeper_down"
    | List -> "masc_keeper_list"
    | Msg -> "masc_keeper_msg"
    | Repair -> "masc_keeper_repair"
    | Reset -> "masc_keeper_reset"
    | Status -> "masc_keeper_status"
    | Up -> "masc_keeper_up"

  let of_string = function
    | "masc_keeper_clear" -> Some Clear
    | "masc_keeper_compact" -> Some Compact
    | "masc_keeper_create_from_persona" -> Some Create_from_persona
    | "masc_keeper_down" -> Some Down
    | "masc_keeper_list" -> Some List
    | "masc_keeper_msg" -> Some Msg
    | "masc_keeper_repair" -> Some Repair
    | "masc_keeper_reset" -> Some Reset
    | "masc_keeper_status" -> Some Status
    | "masc_keeper_up" -> Some Up
    | _ -> None

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

(** Top-level tool identifier.
    [Infra] covers prefix-less infrastructure tools (channel_gate etc.)
    that do not belong to the Keeper/Masc/Masc_keeper surfaces. *)
type infra =
  | Channel_gate

let infra_to_string = function
  | Channel_gate -> "channel_gate"

let infra_of_string = function
  | "channel_gate" -> Some Channel_gate
  | _ -> None

type t =
  | Keeper of Keeper.t
  | Masc of Masc.t
  | Masc_keeper of Masc_keeper.t
  | Infra of infra

let to_string = function
  | Keeper k -> Keeper.to_string k
  | Masc m -> Masc.to_string m
  | Masc_keeper mk -> Masc_keeper.to_string mk
  | Infra i -> infra_to_string i

let of_string s =
  match Keeper.of_string s with
  | Some k -> Some (Keeper k)
  | None ->
    match Masc_keeper.of_string s with
    | Some mk -> Some (Masc_keeper mk)
    | None ->
      match Masc.of_string s with
      | Some m -> Some (Masc m)
      | None ->
        match infra_of_string s with
        | Some i -> Some (Infra i)
        | None -> None

let pp fmt t = Format.pp_print_string fmt (to_string t)

let is_keeper = function Keeper _ -> true | _ -> false
let is_masc = function Masc _ -> true | _ -> false
let is_masc_keeper = function Masc_keeper _ -> true | _ -> false
