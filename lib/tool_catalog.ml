type visibility =
  | Default
  | Hidden

type lifecycle =
  | Active
  | Deprecated

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

type tier =
  | Essential
  | Standard
  | Full

type metadata = {
  visibility : visibility;
  lifecycle : lifecycle;
  implementation_status : implementation_status;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  readonly : bool option;
  destructive : bool option;
  idempotent : bool option;
}

let default_metadata =
  {
    visibility = Default;
    lifecycle = Active;
    implementation_status = Real;
    canonical_name = None;
    replacement = None;
    reason = None;
    allow_direct_call_when_hidden = false;
    readonly = None;
    destructive = None;
    idempotent = None;
  }

(* Runtime-readable like MASC_FULL_SURFACE so tests and local admin flows can
   toggle placeholder exposure without restarting the server. Keep the legacy
   exact-match semantics for "false"/"0" so existing deployments do not change
   behavior when they use other spellings. *)
let placeholder_tools_enabled () =
  match Sys.getenv_opt "MASC_PLACEHOLDER_TOOLS_ENABLED" with
  | Some "false" | Some "0" -> false
  | _ -> true

let deprecated ?canonical_name ?replacement ?(allow_direct_call_when_hidden = false)
    ?(implementation_status = Adapter) reason =
  {
    visibility = Hidden;
    lifecycle = Deprecated;
    implementation_status;
    canonical_name;
    replacement;
    reason = Some reason;
    allow_direct_call_when_hidden;
    readonly = None;
    destructive = None;
    idempotent = None;
  }

let deprecated_default ?canonical_name ?replacement
    ?(implementation_status = Adapter) reason =
  {
    visibility = Default;
    lifecycle = Deprecated;
    implementation_status;
    canonical_name;
    replacement;
    reason = Some reason;
    allow_direct_call_when_hidden = false;
    readonly = None;
    destructive = None;
    idempotent = None;
  }

let hidden_active ?canonical_name ?replacement ?(allow_direct_call_when_hidden = true)
    ?(implementation_status = Real) reason =
  {
    visibility = Hidden;
    lifecycle = Active;
    implementation_status;
    canonical_name;
    replacement;
    reason = Some reason;
    allow_direct_call_when_hidden;
    readonly = None;
    destructive = None;
    idempotent = None;
  }

let with_semantic_flags ?readonly ?destructive ?idempotent meta =
  {
    meta with
    readonly =
      (match readonly with Some value -> Some value | None -> meta.readonly);
    destructive =
      (match destructive with Some value -> Some value | None -> meta.destructive);
    idempotent =
      (match idempotent with Some value -> Some value | None -> meta.idempotent);
  }

let readonly_tool =
  with_semantic_flags ~readonly:true ~idempotent:true default_metadata

let destructive_tool =
  with_semantic_flags ~destructive:true default_metadata

let explicit_metadata : (string * metadata) list =
  [
    ( "masc_post_create",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_post_list",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_post_get",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_comment_add",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_comment_list",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_vote",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_vote_create",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.* or governance V2 tools for primary coordination workflows." );
    ( "masc_vote_cast",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.* or governance V2 tools for primary coordination workflows." );
    ( "masc_vote_status",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.* or governance V2 tools for primary coordination workflows." );
    ( "masc_votes",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.* or governance V2 tools for primary coordination workflows." );
    ( "masc_operator_judgment_write",
      hidden_active
        "Internal operator-judge write path hidden from the default tool list; use for operator judgment experiments and keeper automation." );
    ( "masc_operator_judgment_latest",
      hidden_active
        "Internal operator-judge read path hidden from the default tool list; use for operator judgment experiments and keeper automation." );
    (* Semantic annotations for governance risk classification. *)
    ("masc_status", readonly_tool);
    ("masc_tasks", readonly_tool);
    ("masc_messages", readonly_tool);
    ("masc_who", readonly_tool);
    ("masc_agents", readonly_tool);
    ("masc_dashboard", readonly_tool);
    ("masc_agent_card", readonly_tool);
    ("masc_board_list", readonly_tool);
    ("masc_board_get", readonly_tool);
    ("masc_tool_help", readonly_tool);
    ("masc_keeper_list", readonly_tool);
    ("masc_keeper_status", readonly_tool);
    ("masc_transport_status", readonly_tool);
    ("masc_websocket_discovery", readonly_tool);
    ("masc_plan_get", readonly_tool);
    ("masc_worktree_list", readonly_tool);
    ( "masc_run_get",
      readonly_tool );
    ("masc_run_list", readonly_tool);
    ("masc_execute_dry_run", readonly_tool);
    ( "masc_admin_cleanup",
      with_semantic_flags ~destructive:true
        (hidden_active "Administrative cleanup mutates persisted room state and should be treated as destructive.") );
    ( "masc_admin_reset",
      with_semantic_flags ~destructive:true
        (hidden_active "Administrative reset clears room state and should be treated as destructive.") );
    ( "masc_gc_force",
      with_semantic_flags ~destructive:true
        (hidden_active "Forced garbage collection removes persisted artifacts and should be treated as destructive.") );
    ( "masc_room_delete",
      with_semantic_flags ~destructive:true
        (hidden_active "Room deletion removes persisted state and should be treated as destructive.") );
    ( "masc_room_destroy",
      with_semantic_flags ~destructive:true
        (hidden_active "Room destruction removes persisted state and should be treated as destructive.") );
    ( "masc_force_leave",
      with_semantic_flags ~destructive:true
        (hidden_active "Forced membership removal mutates room state and should be treated as destructive.") );
    ( "masc_force_remove_agent",
      with_semantic_flags ~destructive:true
        (hidden_active "Forced agent removal mutates room state and should be treated as destructive.") );
    ( "masc_operator_action",
      with_semantic_flags ~destructive:true
        (hidden_active "Operator actions can execute privileged side effects and should be treated as destructive.") );
    ( "masc_execute",
      with_semantic_flags ~destructive:true
        (hidden_active "Direct execution can apply privileged side effects and should be treated as destructive.") );
    ("masc_neo4j_query", destructive_tool);
    ("masc_pg_query", destructive_tool);
    ("masc_tool_grant", destructive_tool);
    ("masc_tool_revoke", destructive_tool);
    ( "masc_operation_stop",
      destructive_tool );
    ( "masc_operation_pause",
      { default_metadata with destructive = Some false } );
  ]

(** {1 Public MCP Surface}

    The subset of tools exposed via tools/list on the Full (external MCP client)
    profile. Some hidden tools remain callable directly, but keeper-internal
    adapters do not. This keeps the MCP surface focused on agent communication,
    coordination, and stable public operations.

    Override: set [MASC_FULL_SURFACE=1] to restore the full inventory,
    excluding keeper-internal tools. *)

let public_mcp_tools =
  [
    (* Room lifecycle *)
    "masc_start"; "masc_join"; "masc_leave"; "masc_set_room"; "masc_status";
    (* Messaging *)
    "masc_broadcast"; "masc_messages"; "masc_who";
    (* Task coordination *)
    "masc_add_task"; "masc_batch_add_tasks"; "masc_tasks";
    "masc_claim_next"; "masc_transition";
    (* Planning *)
    "masc_plan_init"; "masc_plan_get"; "masc_plan_set_task"; "masc_plan_update";
    (* Heartbeat *)
    "masc_heartbeat";
    (* Keeper interaction *)
    "masc_keeper_msg"; "masc_keeper_list"; "masc_keeper_status";
    "masc_keeper_up"; "masc_keeper_repair"; "masc_keeper_down";
    (* Board — async agent communication *)
    "masc_board_post"; "masc_board_list"; "masc_board_get";
    "masc_board_comment"; "masc_board_vote"; "masc_board_delete";
    (* Agent discovery *)
    "masc_agents"; "masc_dashboard"; "masc_agent_card";
    (* Transport *)
    "masc_transport_status"; "masc_websocket_discovery";
    "masc_webrtc_offer"; "masc_webrtc_answer";
    (* Utility *)
    "masc_tool_help"; "masc_check";
  ]

let keeper_internal_tools =
  [
    "keeper_read";
    "keeper_fs_read";
    "keeper_fs_edit";
    "keeper_edit";
    "keeper_memory_search";
    "keeper_library_search";
    "keeper_library_read";
    "keeper_time_now";
    "keeper_context_status";
    "keeper_tasks_list";
    "keeper_tasks_audit";
    "keeper_task_claim";
    "keeper_task_done";
    "keeper_task_force_release";
    "keeper_task_force_done";
    "keeper_broadcast";
    "keeper_board_get";
    "keeper_board_post";
    "keeper_board_list";
    "keeper_board_comment";
    "keeper_board_vote";
    "keeper_shell_readonly";
    "keeper_bash";
    "keeper_github";
    "keeper_voice_speak";
    "keeper_voice_agent";
    "keeper_voice_sessions";
    "keeper_voice_session_start";
    "keeper_voice_session_end";
    "keeper_search";
    "keeper_profile";
    "keeper_research";
  ]

let keeper_internal_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length keeper_internal_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) keeper_internal_tools;
  tbl

let keeper_internal_replacement = function
  | "keeper_board_get" -> Some "masc_board_get"
  | "keeper_board_post" -> Some "masc_board_post"
  | "keeper_board_list" -> Some "masc_board_list"
  | "keeper_board_comment" -> Some "masc_board_comment"
  | "keeper_board_vote" -> Some "masc_board_vote"
  | "keeper_voice_speak" -> Some "masc_voice_speak"
  | "keeper_voice_agent" -> Some "masc_voice_agent"
  | "keeper_voice_sessions" -> Some "masc_voice_sessions"
  | "keeper_voice_session_start" -> Some "masc_voice_session_start"
  | "keeper_voice_session_end" -> Some "masc_voice_session_end"
  | "keeper_tasks_list" -> Some "masc_tasks"
  | "keeper_broadcast" -> Some "masc_broadcast"
  | _ -> None

let keeper_internal_metadata name =
  let replacement = keeper_internal_replacement name in
  let implementation_status =
    match replacement with
    | Some _ -> Adapter
    | None -> Real
  in
  hidden_active
    ?canonical_name:replacement
    ?replacement
    ~allow_direct_call_when_hidden:false
    ~implementation_status
    "Keeper-internal tool. Use the keeper runtime or the public MASC equivalent when available."

let public_mcp_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  List.iter (fun name -> Hashtbl.replace tbl name ()) public_mcp_tools;
  (* MASC_PUBLIC_TOOLS_EXTRA: comma-separated tool names to add at runtime.
     Example: MASC_PUBLIC_TOOLS_EXTRA=masc_board_search,masc_pause *)
  (match Env_config.Tools.public_tools_extra_opt () with
   | Some raw ->
       String.split_on_char ',' raw
       |> List.iter (fun s ->
              let name = String.trim s in
              if name <> "" then Hashtbl.replace tbl name ())
   | None -> ());
  tbl

let is_public_mcp name = Hashtbl.mem public_mcp_set name

let full_surface_override () = Env_config.Tools.full_surface_enabled ()

let implementation_status_to_string = function
  | Real -> "real"
  | Adapter -> "adapter"
  | Simulation -> "simulation"
  | Placeholder -> "placeholder"

let implementation_allows_public_visibility = function
  | Real | Adapter -> true
  | Simulation | Placeholder -> false

let metadata name =
  match List.assoc_opt name explicit_metadata with
  | Some meta -> meta
  | None ->
    if is_public_mcp name then default_metadata
    else if Hashtbl.mem keeper_internal_set name then
      keeper_internal_metadata name
    else
      (* Non-public, non-explicit tools are internal: hidden from tools/list
         but callable via tools/call (tool_allowed_in_profile uses include_hidden). *)
      { default_metadata with
        visibility = Hidden;
        allow_direct_call_when_hidden = true;
        reason = Some "Internal tool; not on public MCP surface." }

let implementation_status name =
  let meta = metadata name in
  meta.implementation_status

let is_placeholder name =
  match implementation_status name with
  | Placeholder -> true
  | Real | Adapter | Simulation -> false

let is_visible ?(include_hidden = false) ?(include_deprecated = false) name =
  let meta = metadata name in
  match meta.visibility, meta.lifecycle with
  | Hidden, _ when include_hidden -> true
  | Hidden, _ when placeholder_tools_enabled () && is_placeholder name -> true
  | Hidden, _ -> false
  | Default, Deprecated -> include_deprecated
  | Default, Active -> implementation_allows_public_visibility meta.implementation_status

let visibility_to_string = function
  | Default -> "default"
  | Hidden -> "hidden"

let lifecycle_to_string = function
  | Active -> "active"
  | Deprecated -> "deprecated"

(** Precomputed list of deprecated tools from explicit_metadata.
    Static — computed once at module init. *)
let deprecated_tool_entries : (string * metadata) list =
  List.filter (fun (_name, meta) -> meta.lifecycle = Deprecated) explicit_metadata

(** {1 Tool Tier System}

    3-tier tool filtering to reduce the number of tools presented to models.
    Essential (~20) < Standard (~50) < Full (all).
    Tier is an additive overlay on the existing mode/category system. *)

let essential_tools =
  [
    "masc_join"; "masc_leave"; "masc_status"; "masc_set_room";
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

let metadata_to_fields name =
  let meta = metadata name in
  let base =
    [
      ("visibility", `String (visibility_to_string meta.visibility));
      ("lifecycle", `String (lifecycle_to_string meta.lifecycle));
      ("implementationStatus", `String (implementation_status_to_string meta.implementation_status));
      ("tier", `String (tier_to_string (tool_tier name)));
    ]
  in
  let with_canonical =
    match meta.canonical_name with
    | Some canonical_name -> ("canonicalName", `String canonical_name) :: base
    | None -> base
  in
  let with_replacement =
    match meta.replacement with
    | Some replacement -> ("replacement", `String replacement) :: with_canonical
    | None -> with_canonical
  in
  match meta.reason with
  | Some reason -> ("reason", `String reason) :: with_replacement
  | None -> with_replacement

let public_contract_fields name =
  let meta = metadata name in
  let base =
    [
      ( "implementationStatus",
        `String (implementation_status_to_string meta.implementation_status) );
    ]
  in
  match meta.canonical_name with
  | Some canonical_name -> ("canonicalName", `String canonical_name) :: base
  | None -> base

let allow_direct_call name =
  let meta = metadata name in
  match meta.visibility with
  | Default -> true
  | Hidden -> meta.allow_direct_call_when_hidden

let hidden_placeholder_tools () = []

(** {1 Tool Surface System}

    Canonical per-surface tool name lists — the SSOT for tool surface
    membership. All other modules should derive their allowlists from
    [tools_for_surface] instead of maintaining independent hardcoded lists.

    To add a tool to a surface: add it to the appropriate list below.
    To query surface membership at runtime: use [is_on_surface]. *)

type surface =
  | Public_mcp
  | Spawned_agent
  | Local_worker
  | Session_min
  | Admin
  | Keeper_internal
  | Keeper_denied
  | Mdal_auditable

let public_mcp_surface_tools =
  [
    (* Room lifecycle *)
    "masc_start"; "masc_join"; "masc_leave"; "masc_set_room"; "masc_status";
    (* Messaging *)
    "masc_broadcast"; "masc_messages"; "masc_who";
    (* Task coordination *)
    "masc_add_task"; "masc_batch_add_tasks"; "masc_tasks";
    "masc_claim_next"; "masc_transition";
    (* Planning *)
    "masc_plan_init"; "masc_plan_get"; "masc_plan_set_task"; "masc_plan_update";
    (* Heartbeat *)
    "masc_heartbeat";
    (* Keeper interaction *)
    "masc_keeper_msg"; "masc_keeper_list"; "masc_keeper_status";
    "masc_keeper_up"; "masc_keeper_repair"; "masc_keeper_down";
    (* Board *)
    "masc_board_post"; "masc_board_list"; "masc_board_get";
    "masc_board_comment"; "masc_board_vote"; "masc_board_delete";
    (* Agent discovery *)
    "masc_agents"; "masc_dashboard"; "masc_agent_card";
    (* Transport *)
    "masc_transport_status"; "masc_websocket_discovery";
    "masc_webrtc_offer"; "masc_webrtc_answer";
    (* Utility *)
    "masc_tool_help"; "masc_check";
  ]

let spawned_agent_surface_tools =
  [
    "masc_status"; "masc_tasks"; "masc_claim_next"; "masc_transition";
    "masc_task_history"; "masc_broadcast"; "masc_join"; "masc_leave";
    "masc_who"; "masc_agent_update"; "masc_add_task"; "masc_heartbeat";
    "masc_messages";
    "masc_worktree_create"; "masc_worktree_remove"; "masc_worktree_list";
    "masc_handover_create"; "masc_handover_list"; "masc_handover_claim";
    "masc_handover_get";
    "masc_relay_status"; "masc_relay_checkpoint";
    "masc_board_list"; "masc_board_post"; "masc_board_comment";
    "masc_board_vote"; "masc_board_get";
    "masc_tool_help";
    "masc_portal_open"; "masc_portal_send"; "masc_portal_status";
    "masc_team_session_start"; "masc_team_session_step";
    "masc_team_session_status"; "masc_team_session_events";
    "masc_team_session_finalize"; "masc_team_session_stop";
    "masc_team_session_report"; "masc_team_session_list";
    "masc_a2a_delegate"; "masc_a2a_subscribe";
    "masc_poll_events"; "masc_spawn";
  ]

let local_worker_surface_tools =
  [
    "masc_status"; "masc_tasks"; "masc_claim_next"; "masc_transition";
    "masc_add_task"; "masc_heartbeat";
    "masc_board_post"; "masc_board_list"; "masc_board_get";
    "masc_board_comment"; "masc_board_vote"; "masc_board_search";
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
    "masc_worktree_create"; "masc_worktree_remove"; "masc_worktree_list";
    "masc_run_init"; "masc_run_plan"; "masc_run_log";
    "masc_run_deliverable"; "masc_run_get"; "masc_run_list";
    "masc_repair_loop_start"; "masc_repair_loop_status";
    "masc_repair_loop_iterate"; "masc_repair_loop_stop";
  ]

let session_min_surface_tools =
  [
    "masc_room_status"; "masc_list_tasks"; "masc_claim_next";
    "masc_set_current_task"; "masc_complete_task"; "masc_add_task";
    "masc_broadcast"; "masc_heartbeat";
  ]

let admin_surface_tools =
  [
    "masc_auth_create_token";
    "masc_autoresearch_cycle"; "masc_autoresearch_inject";
    "masc_autoresearch_start"; "masc_autoresearch_stop";
    "masc_autoresearch_swarm_start";
    "masc_repo_synthesis_swarm_start";
    "masc_policy_freeze_unit"; "masc_policy_kill_switch";
    "masc_tool_admin_update"; "masc_tool_grant"; "masc_tool_revoke";
    "masc_operator_action"; "masc_operator_confirm"; "masc_operator_snapshot";
    "masc_team_session_finalize"; "masc_tool_admin_snapshot";
  ]

let keeper_internal_surface_tools = keeper_internal_tools

let keeper_denied_surface_tools =
  [
    "masc_room_delete"; "masc_room_destroy";
    "masc_force_leave"; "masc_force_remove_agent";
    "masc_admin_reset"; "masc_admin_cleanup";
    "masc_gc_force"; "masc_config_set"; "masc_config_reset";
    "masc_spawn";
    "masc_operator_action"; "masc_operator_confirm";
    "masc_operator_judgment_write";
    "masc_execute"; "masc_execute_dry_run";
    "masc_neo4j_query"; "masc_pg_query";
  ]

let mdal_auditable_surface_tools =
  [
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
    "masc_worktree_create"; "masc_worktree_list"; "masc_worktree_remove";
    "masc_run_init"; "masc_run_plan"; "masc_run_log";
    "masc_run_deliverable"; "masc_run_get"; "masc_run_list";
    "masc_spawn";
  ]

let tools_for_surface = function
  | Public_mcp -> public_mcp_surface_tools
  | Spawned_agent -> spawned_agent_surface_tools
  | Local_worker -> local_worker_surface_tools
  | Session_min -> session_min_surface_tools
  | Admin -> admin_surface_tools
  | Keeper_internal -> keeper_internal_surface_tools
  | Keeper_denied -> keeper_denied_surface_tools
  | Mdal_auditable -> mdal_auditable_surface_tools

let all_surfaces =
  [Public_mcp; Spawned_agent; Local_worker; Session_min;
   Admin; Keeper_internal; Keeper_denied; Mdal_auditable]

let surface_sets : (surface * (string, unit) Hashtbl.t) list =
  List.map (fun surface ->
    let tools = tools_for_surface surface in
    let tbl = Hashtbl.create (List.length tools) in
    List.iter (fun name -> Hashtbl.replace tbl name ()) tools;
    (surface, tbl)
  ) all_surfaces

let is_on_surface surface name =
  match List.assoc_opt surface surface_sets with
  | Some tbl -> Hashtbl.mem tbl name
  | None -> false

let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Spawned_agent -> "spawned_agent"
  | Local_worker -> "local_worker"
  | Session_min -> "session_min"
  | Admin -> "admin"
  | Keeper_internal -> "keeper_internal"
  | Keeper_denied -> "keeper_denied"
  | Mdal_auditable -> "mdal_auditable"
