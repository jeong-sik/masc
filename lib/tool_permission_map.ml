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

(** Tool_permission_map — Shared tool→permission resolution. *)

open Masc_domain

let declared_permission_for_tool tool_name =
  match Tool_catalog.registered_metadata tool_name with
  | Some meta -> meta.required_permission
  | None -> None
;;

let fallback_permission_entries : (string * permission) list =
  [ "masc_reset", CanReset
  ; "masc_start", CanJoin
  ; "masc_status", CanReadState
  ; "masc_tasks", CanReadState
  ; "masc_agents", CanReadState
  ; "masc_task_history", CanReadState
  ; "masc_operator_snapshot", CanReadState
  ; "masc_operator_digest", CanReadState
  ; "masc_surface_audit", CanReadState
  ; "masc_persona_schema", CanReadState
  ; "masc_keeper_status", CanReadState
  ; "masc_keeper_list", CanReadState
  ; "masc_keeper_persona_audit", CanReadState
  ; "masc_runtime_verify", CanReadState
  ; "masc_runtime_ollama_probe", CanReadState
  ; "masc_observe_operations", CanReadState
  ; "masc_observe_capacity", CanReadState
  ; "masc_observe_traces", CanReadState
  ; "masc_agent_fitness", CanReadState
  ; "masc_agent_timeline", CanReadState
  ; "masc_dashboard", CanReadState
  ; "masc_check", CanReadState
  ; "masc_approval_pending", CanReadState
  ; "masc_approval_get", CanAdmin
  ; "masc_get_metrics", CanReadState
  ; "masc_plan_get_task", CanReadState
  ; "masc_plan_get", CanReadState
  ; "masc_plan_init", CanBroadcast
  ; "masc_plan_update", CanBroadcast
  ; "masc_plan_set_task", CanBroadcast
  ; "masc_plan_clear_task", CanBroadcast
  ; "masc_note_add", CanBroadcast
  ; "masc_deliver", CanBroadcast
  ; "masc_config", CanReadState
  ; "masc_add_task", CanAddTask
  ; "masc_claim_next", CanClaimTask
  ; "masc_update_priority", CanCompleteTask
  ; "masc_transition", CanCompleteTask
  ; "masc_heartbeat", CanBroadcast
  ; "masc_goal_transition", CanBroadcast
  ; "masc_goal_verify", CanBroadcast
  ; "masc_agent_update", CanBroadcast
  ; "masc_spawn", CanBroadcast
  ; "masc_operator_action", CanBroadcast
  ; "masc_keeper_up", CanBroadcast
  ; "masc_keeper_down", CanBroadcast
  ; "masc_keeper_msg", CanBroadcast
  ; "masc_keeper_msg_result", CanBroadcast
  ; "masc_keeper_repair", CanBroadcast
  ; "masc_persona_generate", CanBroadcast
  ; "masc_persona_save", CanBroadcast
  ; "masc_keeper_create_from_persona", CanBroadcast
  ; "masc_approval_resolve", CanAdmin
  ; "masc_operator_confirm", CanBroadcast
  ; "masc_policy_approve", CanBroadcast
  ; "masc_cleanup_zombies", CanBroadcast
  ; "masc_board_list", CanReadState
  ; "masc_board_get", CanReadState
  ; "masc_board_hearths", CanReadState
  ; "masc_board_search", CanReadState
  ; "masc_board_profile", CanReadState
  ; "masc_board_stats", CanReadState
  ; "masc_board_sub_board_list", CanReadState
  ; "masc_board_sub_board_get", CanReadState
  ; "masc_board_post", CanBroadcast
  ; "masc_board_comment", CanBroadcast
  ; "masc_board_vote", CanBroadcast
  ; "masc_board_comment_vote", CanBroadcast
  ; "masc_board_delete", CanAdmin
  ; "masc_tool_stats", CanReadState
  ; "masc_tool_help", CanReadState
  ; "masc_tool_list", CanReadState
  ; "masc_tool_grant", CanAdmin
  ; "masc_tool_revoke", CanAdmin
  ; "masc_tool_admin_snapshot", CanAdmin
  ; "masc_tool_admin_update", CanAdmin
  ; "masc_run_get", CanReadState
  ; "masc_run_list", CanReadState
  ; "masc_run_init", CanBroadcast
  ; "masc_run_plan", CanBroadcast
  ; "masc_run_log", CanBroadcast
  ; "masc_run_deliverable", CanBroadcast
  ]
;;

(* O(1) lookup table for tools that do not yet declare
   [required_permission] in Tool_catalog metadata.  The fallback table is not a
   second SSOT: metadata wins, and promoted entries should be removed here. *)
let fallback_permission_table : (string, permission) Hashtbl.t =
  let table = Hashtbl.create (List.length fallback_permission_entries * 2) in
  List.iter
    (fun (tool_name, perm) -> Hashtbl.replace table tool_name perm)
    fallback_permission_entries;
  table
;;

let fallback_permission_for_tool tool_name =
  Hashtbl.find_opt fallback_permission_table tool_name
;;

let known_tool_names =
  let metadata_tools =
    Tool_catalog.all_surfaces |> List.concat_map Tool_catalog.tools_for_surface
  in
  let explicit_tools = List.map fst Tool_catalog.explicit_metadata in
  let known = metadata_tools @ explicit_tools @ List.map fst fallback_permission_entries in
  List.sort_uniq String.compare known
;;

let permission_for_tool tool_name =
  match declared_permission_for_tool tool_name with
  | Some _ as permission -> permission
  | None -> fallback_permission_for_tool tool_name
;;
