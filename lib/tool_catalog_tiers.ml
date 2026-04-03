(** Tool_catalog_tiers — 3-tier tool filtering system.

    Essential (~20) < Standard (~50) < Full (all).
    Tier is an additive overlay on the existing mode/category system.

    This module is a leaf dependency — it depends only on string lists.
    Extracted from tool_catalog.ml to enable SCC cycle-breaking:
    keeper modules can depend on this leaf module (e.g. for standard_tools)
    instead of the full Tool_catalog.

    @since 2.188.0 — God file decomposition Phase 1 *)

type tier =
  | Essential
  | Standard
  | Full

let essential_tools =
  [
    "masc_join"; "masc_leave"; "masc_status"; "masc_start";
    "masc_add_task"; "masc_claim_next"; "masc_transition"; "masc_tasks";
    "masc_broadcast"; "masc_heartbeat"; "masc_messages";
    "masc_worktree_create"; "masc_worktree_list"; "masc_worktree_remove";
    "masc_plan_init"; "masc_plan_get"; "masc_plan_set_task"; "masc_plan_update";
    "masc_who"; "masc_dashboard"; "masc_agent_timeline";
  ]

let standard_tools =
  essential_tools
  @ [
    (* Board *)
    "masc_board_post"; "masc_board_get"; "masc_board_list";
    "masc_board_vote"; "masc_board_comment"; "masc_board_comment_vote";
    "masc_board_search"; "masc_board_stats"; "masc_board_profile";
    "masc_board_hearths"; "masc_board_delete";
    (* Team Session *)
    "masc_team_session_start"; "masc_team_session_step";
    "masc_team_session_status"; "masc_team_session_stop";
    "masc_team_session_list"; "masc_team_session_events";
    "masc_autoresearch_swarm_start";
    (* Governance V2 *)
    "masc_petition_submit"; "masc_case_brief_submit";
    "masc_cases"; "masc_case_status";
    "masc_ruling_status"; "masc_execution_orders";
    "masc_governance_status";
    (* Decision *)
    "decision_create"; "decision_finalize"; "decision_status";
    (* Handover *)
    "masc_handover_create"; "masc_handover_claim";
    "masc_handover_get"; "masc_handover_list";
    (* Misc *)
    "masc_spawn"; "masc_agents"; "masc_progress";
    "masc_note_add"; "masc_batch_add_tasks";
    (* Config introspection *)
    "masc_config";
    (* Phase 2 surface SSOT — worker-facing tools *)
    "masc_code_edit"; "masc_code_write"; "masc_code_read";
    "masc_code_git"; "masc_code_shell";
    "masc_deliver"; "masc_plan_clear_task"; "masc_plan_get_task";
    "masc_verify_request"; "masc_verify_status"; "masc_verify_submit";
    "masc_improve_loop_start"; "masc_improve_loop_status";
    "masc_library_search"; "masc_library_read";
    "masc_workflow_guide";
  ]

(** Pre-built Hashtbl sets for O(1) tier lookups.
    The lists above are kept for enumeration/documentation. *)
let essential_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun name -> Hashtbl.replace tbl name ()) essential_tools;
  tbl

let standard_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  List.iter (fun name -> Hashtbl.replace tbl name ()) standard_tools;
  tbl

let tier_to_string = function
  | Essential -> "essential"
  | Standard -> "standard"
  | Full -> "full"

let tier_of_string = function
  | "essential" -> Some Essential
  | "standard" -> Some Standard
  | "full" -> Some Full
  | _ -> None

let tool_tier name =
  if Hashtbl.mem essential_set name then Essential
  else if Hashtbl.mem standard_set name then Standard
  else Full

let is_in_tier tier name =
  match tier with
  | Full -> true
  | Standard -> Hashtbl.mem standard_set name
  | Essential -> Hashtbl.mem essential_set name

let tier_tool_count = function
  | Essential -> List.length essential_tools
  | Standard -> List.length standard_tools
  | Full -> -1  (* unknown until schemas are enumerated *)
