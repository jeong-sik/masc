(** Tool_name — Compile-time verified tool identifiers.

    Replaces stringly-typed tool dispatch with exhaustive variant matching.
    Parse boundary: [of_string] at MCP/JSON ingress only.
    Internal code uses [t] directly — typos become compile errors. *)

module Keeper = struct
  type t =
    | Bash | Bash_kill | Bash_output
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
  let to_string = function
    | Bash -> "keeper_bash"
    | Bash_kill -> "keeper_bash_kill"
    | Bash_output -> "keeper_bash_output"
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
    | Preflight_check -> "keeper_preflight_check"
    | Shell -> "keeper_shell"
    | Stay_silent -> "keeper_stay_silent"
    | Task_claim -> "keeper_task_claim"
    | Task_create -> "keeper_task_create"
    | Task_done -> "keeper_task_done"
    | Task_submit_for_verification -> "keeper_task_submit_for_verification"
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
    | Write -> "keeper_write"
  let of_string = function
    | "keeper_bash" -> Some Bash
    | "keeper_bash_kill" -> Some Bash_kill
    | "keeper_bash_output" -> Some Bash_output
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
    | "keeper_preflight_check" -> Some Preflight_check
    | "keeper_shell" -> Some Shell
    | "keeper_stay_silent" -> Some Stay_silent
    | "keeper_task_claim" -> Some Task_claim
    | "keeper_task_create" -> Some Task_create
    | "keeper_task_done" -> Some Task_done
    | "keeper_task_submit_for_verification" -> Some Task_submit_for_verification
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
    | "keeper_write" -> Some Write
    | _ -> None

  let board_write_tools = [ Board_post; Board_comment; Board_vote ]

  let board_write_tool_names = List.map to_string board_write_tools

  let is_board = function
    | Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_delete
    | Board_get
    | Board_list
    | Board_post
    | Board_search
    | Board_stats
    | Board_vote -> true
    | _ -> false

  let is_board_write = function
    | Board_post | Board_comment | Board_vote -> true
    | _ -> false

  let board_write_action_kind = function
    | Board_post -> Some "post"
    | Board_comment -> Some "comment"
    | Board_vote -> Some "vote"
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
    | Autoresearch_record_finding
    | Autoresearch_search_findings
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
    | Web_search
    | Who
    | Workflow_guide
    | Worktree_create
    | Worktree_list
    | Worktree_remove
    | Approval_get
    | Collaboration_graph
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
    | Coordination_fsm_snapshot -> "masc_coordination_fsm_snapshot"
    | Autoresearch_cycle -> "masc_autoresearch_cycle"
    | Autoresearch_inject -> "masc_autoresearch_inject"
    | Autoresearch_record_finding -> "masc_autoresearch_record_finding"
    | Autoresearch_search_findings -> "masc_autoresearch_search_findings"
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
    | Dispatch_plan -> "masc_dispatch_plan"
    | Goal_list -> "masc_goal_list"
    | Goal_review -> "masc_goal_review"
    | Goal_transition -> "masc_goal_transition"
    | Goal_upsert -> "masc_goal_upsert"
    | Goal_verify -> "masc_goal_verify"
    | Heartbeat -> "masc_heartbeat"
    | Join -> "masc_join"
    | Leave -> "masc_leave"
    | List_tasks -> "masc_list_tasks"
    | Messages -> "masc_messages"
    | Note_add -> "masc_note_add"
    | Operation_pause -> "masc_operation_pause"
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
    | Coord_status -> "masc_room_status"
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
    | Approval_get -> "masc_approval_get"
    | Collaboration_graph -> "masc_collaboration_graph"
    | Config -> "masc_config"
    | Gc -> "masc_gc"
    | Get_metrics -> "masc_get_metrics"
    | Mcp_session -> "masc_mcp_session"
    | Pause -> "masc_pause"
    | Resume -> "masc_resume"
    | Spawn -> "masc_spawn"
    | Start -> "masc_start"
    | Tool_admin_snapshot -> "masc_tool_admin_snapshot"
    | Tool_admin_update -> "masc_tool_admin_update"
    | Tool_stats -> "masc_tool_stats"
    | Webrtc_answer -> "masc_webrtc_answer"
    | Webrtc_offer -> "masc_webrtc_offer"

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
    | "masc_coordination_fsm_snapshot" -> Some Coordination_fsm_snapshot
    | "masc_autoresearch_cycle" -> Some Autoresearch_cycle
    | "masc_autoresearch_inject" -> Some Autoresearch_inject
    | "masc_autoresearch_record_finding" -> Some Autoresearch_record_finding
    | "masc_autoresearch_search_findings" -> Some Autoresearch_search_findings
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
    | "masc_dispatch_plan" -> Some Dispatch_plan
    | "masc_goal_list" -> Some Goal_list
    | "masc_goal_review" -> Some Goal_review
    | "masc_goal_transition" -> Some Goal_transition
    | "masc_goal_upsert" -> Some Goal_upsert
    | "masc_goal_verify" -> Some Goal_verify
    | "masc_heartbeat" -> Some Heartbeat
    | "masc_join" -> Some Join
    | "masc_leave" -> Some Leave
    | "masc_list_tasks" -> Some List_tasks
    | "masc_messages" -> Some Messages
    | "masc_note_add" -> Some Note_add
    | "masc_operation_pause" -> Some Operation_pause
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
    | "masc_room_status" -> Some Coord_status
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
    | "masc_approval_get" -> Some Approval_get
    | "masc_collaboration_graph" -> Some Collaboration_graph
    | "masc_config" -> Some Config
    | "masc_gc" -> Some Gc
    | "masc_get_metrics" -> Some Get_metrics
    | "masc_mcp_session" -> Some Mcp_session
    | "masc_pause" -> Some Pause
    | "masc_resume" -> Some Resume
    | "masc_spawn" -> Some Spawn
    | "masc_start" -> Some Start
    | "masc_tool_admin_snapshot" -> Some Tool_admin_snapshot
    | "masc_tool_admin_update" -> Some Tool_admin_update
    | "masc_tool_stats" -> Some Tool_stats
    | "masc_webrtc_answer" -> Some Webrtc_answer
    | "masc_webrtc_offer" -> Some Webrtc_offer
    | _ -> None

  let is_board = function
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
    | Board_vote -> true
    | _ -> false

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
    | Persona_audit
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
    | Persona_audit -> "masc_keeper_persona_audit"
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
    | "masc_keeper_persona_audit" -> Some Persona_audit
    | "masc_keeper_repair" -> Some Repair
    | "masc_keeper_reset" -> Some Reset
    | "masc_keeper_status" -> Some Status
    | "masc_keeper_up" -> Some Up
    | _ -> None

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

type t =
  | Keeper of Keeper.t
  | Masc of Masc.t
  | Masc_keeper of Masc_keeper.t

let to_string = function
  | Keeper k -> Keeper.to_string k
  | Masc m -> Masc.to_string m
  | Masc_keeper mk -> Masc_keeper.to_string mk

let of_string s =
  match Keeper.of_string s with
  | Some k -> Some (Keeper k)
  | None ->
    match Masc_keeper.of_string s with
    | Some mk -> Some (Masc_keeper mk)
    | None ->
      match Masc.of_string s with
      | Some m -> Some (Masc m)
      | None -> None

let pp fmt t = Format.pp_print_string fmt (to_string t)

let is_keeper = function Keeper _ -> true | _ -> false
let is_masc = function Masc _ -> true | _ -> false
let is_masc_keeper = function Masc_keeper _ -> true | _ -> false

let is_board = function
  | Keeper k -> Keeper.is_board k
  | Masc m -> Masc.is_board m
  | Masc_keeper _ -> false
