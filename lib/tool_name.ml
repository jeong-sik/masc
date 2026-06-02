module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_name — Compile-time verified tool identifiers.

    Replaces stringly-typed tool dispatch with exhaustive variant matching.
    Parse boundary: [of_string] at MCP/JSON ingress only.
    Internal code uses [t] directly — typos become compile errors. *)

module Masc = struct
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

  let to_string = function
    | Add_task -> "masc_add_task"
    | Agent_fitness -> "masc_agent_fitness"
    | Agent_update -> "masc_agent_update"
    | Agent_card -> "masc_agent_card"
    | Agents -> "masc_agents"
    | Batch_add_tasks -> "masc_batch_add_tasks"
    | Board_cleanup -> "masc_board_cleanup"
    | Board_comment -> "masc_board_comment"
    | Board_comment_vote -> "masc_board_comment_vote"
    | Board_curation_read -> "masc_board_curation_read"
    | Board_curation_submit -> "masc_board_curation_submit"
    | Board_delete -> "masc_board_delete"
    | Board_get -> "masc_board_get"
    | Board_hearths -> "masc_board_hearths"
    | Board_list -> "masc_board_list"
    | Board_post -> "masc_board_post"
    | Board_profile -> "masc_board_profile"
    | Board_reaction -> "masc_board_reaction"
    | Board_search -> "masc_board_search"
    | Board_stats -> "masc_board_stats"
    | Board_sub_board_create -> "masc_board_sub_board_create"
    | Board_sub_board_delete -> "masc_board_sub_board_delete"
    | Board_sub_board_get -> "masc_board_sub_board_get"
    | Board_sub_board_list -> "masc_board_sub_board_list"
    | Board_sub_board_update -> "masc_board_sub_board_update"
    | Board_vote -> "masc_board_vote"
    | Broadcast -> "masc_broadcast"
    | Check -> "masc_check"
    | Claim_next -> "masc_claim_next"
    | Cleanup_zombies -> "masc_cleanup_zombies"
    | Dashboard -> "masc_dashboard"
    | Deliver -> "masc_deliver"
    | Goal_list -> "masc_goal_list"
    | Goal_transition -> "masc_goal_transition"
    | Goal_upsert -> "masc_goal_upsert"
    | Goal_verify -> "masc_goal_verify"
    | Heartbeat -> "masc_heartbeat"
    | Messages -> "masc_messages"
    | Note_add -> "masc_note_add"
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
    | Reset -> "masc_reset"
    | Status -> "masc_status"
    | Task_history -> "masc_task_history"
    | Tasks -> "masc_tasks"
    | Tool_grant -> "masc_tool_grant"
    | Tool_help -> "masc_tool_help"
    | Tool_list -> "masc_tool_list"
    | Tool_revoke -> "masc_tool_revoke"
    | Transition -> "masc_transition"
    | Update_priority -> "masc_update_priority"
    | Web_fetch -> "masc_web_fetch"
    | Web_search -> "masc_web_search"
    | Approval_pending -> "masc_approval_pending"
    | Approval_get -> "masc_approval_get"
    | Config -> "masc_config"
    | Gc -> "masc_gc"
    | Get_metrics -> "masc_get_metrics"
    | Mcp_session -> "masc_mcp_session"
    | Pause -> "masc_pause"
    | Resume -> "masc_resume"
    | Start -> "masc_start"
    | Tool_admin_snapshot -> "masc_tool_admin_snapshot"
    | Tool_admin_update -> "masc_tool_admin_update"
    | Tool_stats -> "masc_tool_stats"
  ;;

  let of_string = function
    | "masc_add_task" -> Some Add_task
    | "masc_agent_fitness" -> Some Agent_fitness
    | "masc_agent_update" -> Some Agent_update
    | "masc_agent_card" -> Some Agent_card
    | "masc_agents" -> Some Agents
    | "masc_batch_add_tasks" -> Some Batch_add_tasks
    | "masc_board_cleanup" -> Some Board_cleanup
    | "masc_board_comment" -> Some Board_comment
    | "masc_board_comment_vote" -> Some Board_comment_vote
    | "masc_board_curation_read" -> Some Board_curation_read
    | "masc_board_curation_submit" -> Some Board_curation_submit
    | "masc_board_delete" -> Some Board_delete
    | "masc_board_get" -> Some Board_get
    | "masc_board_hearths" -> Some Board_hearths
    | "masc_board_list" -> Some Board_list
    | "masc_board_post" -> Some Board_post
    | "masc_board_profile" -> Some Board_profile
    | "masc_board_reaction" -> Some Board_reaction
    | "masc_board_search" -> Some Board_search
    | "masc_board_stats" -> Some Board_stats
    | "masc_board_vote" -> Some Board_vote
    | "masc_board_sub_board_create" -> Some Board_sub_board_create
    | "masc_board_sub_board_delete" -> Some Board_sub_board_delete
    | "masc_board_sub_board_get" -> Some Board_sub_board_get
    | "masc_board_sub_board_list" -> Some Board_sub_board_list
    | "masc_board_sub_board_update" -> Some Board_sub_board_update
    | "masc_broadcast" -> Some Broadcast
    | "masc_check" -> Some Check
    | "masc_claim_next" -> Some Claim_next
    | "masc_cleanup_zombies" -> Some Cleanup_zombies
    | "masc_dashboard" -> Some Dashboard
    | "masc_deliver" -> Some Deliver
    | "masc_goal_list" -> Some Goal_list
    | "masc_goal_transition" -> Some Goal_transition
    | "masc_goal_upsert" -> Some Goal_upsert
    | "masc_goal_verify" -> Some Goal_verify
    | "masc_heartbeat" -> Some Heartbeat
    | "masc_messages" -> Some Messages
    | "masc_note_add" -> Some Note_add
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
    | "masc_reset" -> Some Reset
    | "masc_status" -> Some Status
    | "masc_task_history" -> Some Task_history
    | "masc_tasks" -> Some Tasks
    | "masc_tool_grant" -> Some Tool_grant
    | "masc_tool_help" -> Some Tool_help
    | "masc_tool_list" -> Some Tool_list
    | "masc_tool_revoke" -> Some Tool_revoke
    | "masc_transition" -> Some Transition
    | "masc_update_priority" -> Some Update_priority
    | "masc_web_fetch" -> Some Web_fetch
    | "masc_web_search" -> Some Web_search
    | "masc_approval_pending" -> Some Approval_pending
    | "masc_approval_get" -> Some Approval_get
    | "masc_config" -> Some Config
    | "masc_gc" -> Some Gc
    | "masc_get_metrics" -> Some Get_metrics
    | "masc_mcp_session" -> Some Mcp_session
    | "masc_pause" -> Some Pause
    | "masc_resume" -> Some Resume
    | "masc_start" -> Some Start
    | "masc_tool_admin_snapshot" -> Some Tool_admin_snapshot
    | "masc_tool_admin_update" -> Some Tool_admin_update
    | "masc_tool_stats" -> Some Tool_stats
    | _ -> None
  ;;

  let is_board = function
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
    | Board_vote -> true
    | _ -> false
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

type t =
  | Masc of Masc.t

let to_string = function
  | Masc m -> Masc.to_string m
;;

let of_string s =
  match Masc.of_string s with
  | Some m -> Some (Masc m)
  | None -> None
;;

let pp fmt t = Format.pp_print_string fmt (to_string t)

let is_masc = function
  | Masc _ -> true
;;

let is_board = function
  | Masc m -> Masc.is_board m
;;
