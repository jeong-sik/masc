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

let legacy_permission_entries : (string * permission) list =
  [
    ("masc_reset", CanReset);
    ("masc_join", CanJoin);
    ("masc_leave", CanLeave);
    ("masc_status", CanReadState);
    ("masc_who", CanReadState);
    ("masc_tasks", CanReadState);
    ("masc_messages", CanReadState);
    ("masc_agents", CanReadState);
    ("masc_agent_card", CanReadState);
    ("masc_worktree_list", CanReadState);
    ("masc_task_history", CanReadState);
    ("masc_operator_snapshot", CanReadState);
    ("masc_operator_digest", CanReadState);
    ("masc_surface_audit", CanReadState);
    ("masc_persona_schema", CanReadState);
    ("masc_keeper_status", CanReadState);
    ("masc_keeper_list", CanReadState);
    ("masc_keeper_persona_audit", CanReadState);
    ("masc_runtime_verify", CanReadState);
    ("masc_runtime_ollama_probe", CanReadState);
    ("masc_operation_status", CanReadState);
    ("masc_dispatch_plan", CanReadState);
    ("masc_observe_operations", CanReadState);
    ("masc_observe_capacity", CanReadState);
    ("masc_observe_traces", CanReadState);    ("masc_agent_fitness", CanReadState);
    ("masc_dashboard", CanReadState);
    ("masc_check", CanReadState);
    ("masc_coordination_fsm_snapshot", CanReadState);
    ("masc_approval_pending", CanReadState);
    ("masc_approval_get", CanAdmin);
    ("masc_get_metrics", CanReadState);
    ("masc_plan_get_task", CanReadState);
    ("masc_plan_get", CanReadState);
    ("masc_workflow_guide", CanReadState);
    ("masc_autoresearch_search_findings", CanReadState);
    ("masc_autoresearch_status", CanReadState);
    ("masc_config", CanReadState);
    ("masc_add_task", CanAddTask);
    ("masc_claim_next", CanClaimTask);
    ("masc_update_priority", CanCompleteTask);
    ("masc_transition", CanCompleteTask);
    ("masc_broadcast", CanBroadcast);
    ("masc_heartbeat", CanBroadcast);
    ("masc_goal_transition", CanBroadcast);
    ("masc_goal_verify", CanBroadcast);
    ("masc_webrtc_offer", CanBroadcast);
    ("masc_webrtc_answer", CanBroadcast);
    ("channel_gate", CanBroadcast);
    ("masc_register_capabilities", CanBroadcast);
    ("masc_agent_update", CanBroadcast);
    ("masc_operator_action", CanBroadcast);
    ("masc_keeper_up", CanBroadcast);
    ("masc_keeper_down", CanBroadcast);
    ("masc_keeper_msg", CanBroadcast);
    ("masc_keeper_msg_result", CanBroadcast);
    ("masc_keeper_repair", CanBroadcast);
    ("masc_keeper_reset", CanBroadcast);
    ("masc_keeper_compact", CanBroadcast);
    ("masc_keeper_clear", CanBroadcast);
    ("sidecar", CanBroadcast);
    ("masc_persona_generate", CanBroadcast);
    ("masc_persona_save", CanBroadcast);
    ("masc_keeper_create_from_persona", CanBroadcast);
    ("masc_approval_resolve", CanAdmin);
    ("masc_operator_confirm", CanBroadcast);
    ("masc_operation_start", CanBroadcast);
    ("masc_policy_approve", CanBroadcast);
    ("masc_cleanup_zombies", CanBroadcast);
    ("masc_autoresearch_start", CanAdmin);
    ("masc_autoresearch_record_finding", CanAdmin);
    (* Issue #8661: dropped masc_autoresearch_swarm_start /
       masc_repo_synthesis_swarm_start — tools were retired with the
       swarm cleanup (#8559) and tests in test_tool_access_policy.ml
       and test_tool_shard_coverage.ml already pin them as not present.
       Permission map entries were dead surface granting CanAdmin to
       non-existent tools. *)
    ("masc_autoresearch_cycle", CanAdmin);
    ("masc_autoresearch_inject", CanAdmin);
    ("masc_autoresearch_stop", CanAdmin);
    ("masc_board_list", CanReadState);
    ("masc_board_get", CanReadState);
    ("masc_board_hearths", CanReadState);
    ("masc_board_search", CanReadState);
    ("masc_board_profile", CanReadState);
    ("masc_board_stats", CanReadState);
    ("masc_board_post", CanBroadcast);
    ("masc_board_comment", CanBroadcast);
    ("masc_board_vote", CanBroadcast);
    ("masc_board_comment_vote", CanBroadcast);
    ("masc_board_delete", CanAdmin);
    ("masc_tool_stats", CanReadState);
    ("masc_tool_help", CanReadState);
    ("masc_tool_list", CanReadState);
    ("masc_tool_grant", CanAdmin);
    ("masc_tool_revoke", CanAdmin);
    ("masc_tool_admin_snapshot", CanAdmin);
    ("masc_tool_admin_update", CanAdmin);
    ("masc_portal_open", CanOpenPortal);
    ("masc_portal_close", CanOpenPortal);
    ("masc_portal_send", CanSendPortal);
    ("masc_worktree_create", CanCreateWorktree);
    ("masc_worktree_remove", CanRemoveWorktree);
  ]

(* O(1) lookup table built once at module load.  Previously
   [legacy_permission_for_tool] scanned [legacy_permission_entries]
   (~97 entries) via [List.assoc_opt] on every call; this is hot on the
   auth path ([Auth.authorize] → [permission_for_tool] → here for every
   request that misses the declared metadata).  The entries list
   remains the readable source-of-truth and feeds [known_tool_names]
   below. *)
let legacy_permission_table : (string, permission) Hashtbl.t =
  let table =
    Hashtbl.create (List.length legacy_permission_entries * 2)
  in
  List.iter
    (fun (tool_name, perm) -> Hashtbl.replace table tool_name perm)
    legacy_permission_entries;
  table

let legacy_permission_for_tool tool_name =
  Hashtbl.find_opt legacy_permission_table tool_name

let known_tool_names =
  let metadata_tools =
    Tool_catalog.all_surfaces
    |> List.concat_map Tool_catalog.tools_for_surface
  in
  let explicit_tools = List.map fst Tool_catalog.explicit_metadata in
  let known = metadata_tools @ explicit_tools @ List.map fst legacy_permission_entries in
  List.sort_uniq String.compare known

let permission_for_tool tool_name =
  match declared_permission_for_tool tool_name with
  | Some _ as permission -> permission
  | None -> legacy_permission_for_tool tool_name
