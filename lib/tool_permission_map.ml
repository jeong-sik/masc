(** Tool_permission_map — Shared tool→permission resolution. *)

open Types

let declared_permission_for_tool tool_name =
  (Tool_catalog.metadata tool_name).required_permission

(* Variant-sourced permission entries: typos become compile errors. *)
let legacy_permission_typed : (Tool_name.t * permission) list =
  let open Tool_name in
  [
    (* Room lifecycle *)
    (Masc Reset, CanReset);
    (Masc Join, CanJoin);
    (Masc Leave, CanLeave);
    (* Read-only state queries *)
    (Masc Status, CanReadState);
    (Masc Who, CanReadState);
    (Masc Tasks, CanReadState);
    (Masc Messages, CanReadState);
    (Masc Agents, CanReadState);
    (Masc Worktree_list, CanReadState);
    (Masc Task_history, CanReadState);
    (Masc Operator_snapshot, CanReadState);
    (Masc Operator_digest, CanReadState);
    (Masc Surface_audit, CanReadState);
    (Masc_keeper Status, CanReadState);
    (Masc_keeper List, CanReadState);
    (Masc Runtime_verify, CanReadState);
    (Masc Runtime_ollama_probe, CanReadState);
    (Masc Operation_status, CanReadState);
    (Masc Dispatch_plan, CanReadState);
    (Masc Agent_card, CanReadState);
    (Masc Agent_fitness, CanReadState);
    (Masc Dashboard, CanReadState);
    (Masc Check, CanReadState);
    (Masc Get_metrics, CanReadState);
    (Masc Plan_get_task, CanReadState);
    (Masc Plan_get, CanReadState);
    (Masc Workflow_guide, CanReadState);
    (Masc Autoresearch_status, CanReadState);
    (Masc Config, CanReadState);
    (* Task / broadcast *)
    (Masc Add_task, CanAddTask);
    (Masc Claim_next, CanClaimTask);
    (Masc Update_priority, CanCompleteTask);
    (Masc Transition, CanCompleteTask);
    (Masc Broadcast, CanBroadcast);
    (Masc Heartbeat, CanBroadcast);
    (Masc Webrtc_offer, CanBroadcast);
    (Masc Webrtc_answer, CanBroadcast);
    (Masc Register_capabilities, CanBroadcast);
    (Masc Agent_update, CanBroadcast);
    (Masc Operator_action, CanBroadcast);
    (Masc_keeper Up, CanBroadcast);
    (Masc_keeper Down, CanBroadcast);
    (Masc_keeper Msg, CanBroadcast);
    (Masc Keeper_msg_result, CanBroadcast);
    (Masc_keeper Repair, CanBroadcast);
    (Masc_keeper Reset, CanBroadcast);
    (Masc_keeper Compact, CanBroadcast);
    (Masc_keeper Clear, CanBroadcast);
    (Masc_keeper Create_from_persona, CanBroadcast);
    (Masc Operator_confirm, CanBroadcast);
    (Masc Operation_start, CanBroadcast);
    (Masc Operation_checkpoint, CanBroadcast);
    (Masc Operation_pause, CanBroadcast);
    (Masc Operation_resume, CanBroadcast);
    (Masc Operation_stop, CanBroadcast);
    (Masc Operation_finalize, CanBroadcast);
    (Masc Dispatch_assign, CanBroadcast);
    (Masc Cleanup_zombies, CanBroadcast);
    (* Admin *)
    (Masc Autoresearch_start, CanAdmin);
    (Masc Autoresearch_cycle, CanAdmin);
    (Masc Autoresearch_inject, CanAdmin);
    (Masc Autoresearch_stop, CanAdmin);
    (* Board *)
    (Masc Board_list, CanReadState);
    (Masc Board_get, CanReadState);
    (Masc Board_hearths, CanReadState);
    (Masc Board_search, CanReadState);
    (Masc Board_profile, CanReadState);
    (Masc Board_stats, CanReadState);
    (Masc Board_post, CanBroadcast);
    (Masc Board_comment, CanBroadcast);
    (Masc Board_vote, CanBroadcast);
    (Masc Board_comment_vote, CanBroadcast);
    (Masc Board_delete, CanAdmin);
    (* Tool admin *)
    (Masc Tool_stats, CanReadState);
    (Masc Tool_help, CanReadState);
    (Masc Tool_list, CanReadState);
    (Masc Tool_grant, CanAdmin);
    (Masc Tool_revoke, CanAdmin);
    (Masc Tool_admin_snapshot, CanReadState);
    (Masc Tool_admin_update, CanAdmin);
    (* Worktree mutation *)
    (Masc Worktree_create, CanCreateWorktree);
    (Masc Worktree_remove, CanRemoveWorktree);
  ]

let legacy_permission_entries : (string * permission) list =
  List.map (fun (t, p) -> (Tool_name.to_string t, p)) legacy_permission_typed
  @ [
    (* channel_gate is an HTTP endpoint auth marker, not a registered tool. *)
    ("channel_gate", CanBroadcast);
  ]

let legacy_permission_for_tool tool_name =
  List.assoc_opt tool_name legacy_permission_entries

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
