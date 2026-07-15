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

(** Tool_catalog — Visibility metadata for MCP tools.

    Central registry for tool access control:
    - Visibility: Default (public) vs Hidden (internal-only)
    - Implementation status: Real, Adapter, Simulation, Placeholder
    - Surface: Canonical per-surface tool name membership SSOT

    Sub-module:
    - Tool_catalog_surfaces: surface type and canonical tool lists

    @since 2.188.0 — Decomposed from monolithic tool_catalog.ml *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type visibility =
  | Default
  | Hidden

type lifecycle =
  | Active

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

type metadata = {
  visibility : visibility;
  lifecycle : lifecycle;
  implementation_status : implementation_status;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  readonly : bool option;
  mcp_context_required : bool option;
  idempotent : bool option;
}

type execution_policy_axis =
  | Read_only_axis
  | Idempotent_axis
  | Mcp_context_required_axis

type execution_policy = {
  is_read_only : bool;
  is_idempotent : bool;
  mcp_context_required : bool;
}

type execution_policy_error =
  | Missing_execution_policy of
      { tool_name : string
      ; missing_axes : execution_policy_axis list
      }

let execution_policy_axis_to_string = function
  | Read_only_axis -> "readonly"
  | Idempotent_axis -> "idempotent"
  | Mcp_context_required_axis -> "mcp_context_required"
;;

let execution_policy_error_to_string = function
  | Missing_execution_policy { tool_name; missing_axes } ->
    Printf.sprintf
      "tool %s is missing required execution policy metadata: %s"
      tool_name
      (missing_axes
       |> List.map execution_policy_axis_to_string
       |> String.concat ", ")
;;

let execution_policy_of_metadata ~tool_name (metadata : metadata) =
  match
    ( metadata.readonly
    , metadata.idempotent
    , metadata.mcp_context_required )
  with
  | Some is_read_only, Some is_idempotent, Some mcp_context_required ->
    Ok { is_read_only; is_idempotent; mcp_context_required }
  | readonly, idempotent, mcp_context_required ->
    let missing_axes =
      [ Option.fold ~none:(Some Read_only_axis) ~some:(fun _ -> None) readonly
      ; Option.fold ~none:(Some Idempotent_axis) ~some:(fun _ -> None) idempotent
      ; Option.fold
          ~none:(Some Mcp_context_required_axis)
          ~some:(fun _ -> None)
          mcp_context_required
      ]
      |> List.filter_map Fun.id
    in
    Error (Missing_execution_policy { tool_name; missing_axes })
;;

(* ================================================================ *)
(* Metadata constructors                                            *)
(* ================================================================ *)

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
    mcp_context_required = None;
    idempotent = None;
  }

(* Runtime-readable so tests and local admin flows can toggle placeholder
   exposure without restarting the server. Keep the legacy exact-match
   semantics for "false"/"0" so existing deployments do not change behavior
   when they use other spellings. *)
let placeholder_tools_enabled () =
  match Sys.getenv_opt "MASC_PLACEHOLDER_TOOLS_ENABLED" with
  | Some "false" | Some "0" -> false
  | _ -> true

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
    mcp_context_required = None;
    idempotent = None;
  }

let with_semantic_flags ?readonly ?mcp_context_required ?idempotent meta =
  {
    meta with
    readonly =
      (match readonly with Some value -> Some value | None -> meta.readonly);
    mcp_context_required =
      (match mcp_context_required with
      | Some value -> Some value
      | None -> meta.mcp_context_required);
    idempotent =
      (match idempotent with Some value -> Some value | None -> meta.idempotent);
  }

let with_execution_policy
    ~readonly
    ~idempotent
    ?(mcp_context_required = false)
    meta
  =
  with_semantic_flags
    ~readonly
    ~idempotent
    ~mcp_context_required
    meta
;;

let readonly_tool =
  with_execution_policy
    ~readonly:true
    ~idempotent:false
    default_metadata

let mutating_tool =
  with_execution_policy
    ~readonly:false
    ~idempotent:false
    default_metadata

let masc_workspace_tool =
  with_execution_policy
    ~readonly:false
    ~idempotent:false
    default_metadata

let read_state_tool = readonly_tool
let broadcast_tool = masc_workspace_tool
let add_task_tool = masc_workspace_tool
let claim_task_tool = masc_workspace_tool
let complete_task_tool = masc_workspace_tool
let reset_tool = mutating_tool

let hidden_runtime_tool reason meta =
  {
    meta with
    visibility = Hidden;
    allow_direct_call_when_hidden = true;
    reason = Some reason;
  }

(* ================================================================ *)
(* Explicit metadata registry                                       *)
(* ================================================================ *)

let explicit_metadata : (string * metadata) list =
  [
    ( "masc_operator_judgment_write",
      hidden_active
        "Internal operator-judge write path hidden from the default tool list; use for operator judgment experiments and automation." );
    (* Physically removed: masc_interrupt, masc_approve, masc_reject,
       masc_pending_interrupts, masc_branch (masc-checkpoint CLI removed,
       #4709/#4734), operator_judgment_latest, hat_wear, hat_status,
       encryption_*, generate_key, tempo*, cost_log, cost_report (#4709/#4757). *)
    (* Explicit execution metadata for registered tools. *)
    ("masc_status", read_state_tool);
    ("masc_tasks", read_state_tool);
    ("masc_messages", with_semantic_flags ~mcp_context_required:true read_state_tool);
    ("masc_agent_card", read_state_tool);
    ("masc_dashboard", read_state_tool);
    ("masc_board_list", read_state_tool);
    ("masc_board_post_get", read_state_tool);
    ("masc_board_curation_read", read_state_tool);
    ( "masc_board_curation_submit",
      broadcast_tool );
    ("masc_tool_help", read_state_tool);
    ("masc_plan_get", broadcast_tool);
    ("masc_transition", complete_task_tool);
    ("masc_plan_set_task", broadcast_tool);
    ("masc_broadcast", with_semantic_flags ~mcp_context_required:true broadcast_tool);
    ("channel_gate", broadcast_tool);
    (* Run schemas register from tool_run.ml; catalog still owns early auth metadata.
       RFC-0182: 7 dead admin tools (masc_execute_dry_run, masc_admin_cleanup,
       masc_admin_reset, masc_gc_force, masc_workspace_delete, masc_force_unbind,
       masc_execute) removed — no dispatch path, no schema, no caller. *)
    ( "masc_operator_action",
      hidden_active "Internal operator-action route; hidden from the public tool surface." );
    ( "masc_operator_chat_recovery_resolve",
      with_execution_policy
        ~readonly:false
        ~idempotent:false
        (hidden_active
           ~allow_direct_call_when_hidden:false
           "Operator-profile-only exact recovery of one crash-ambiguous Keeper chat receipt.") );
    ( "masc_set_param",
      hidden_active
        "Internal HTTP runtime-parameter mutation route; hidden from the public tool surface." );
    (* Catalog-owned permissions for split/lazily registered tool modules. *)
    ("masc_reset", reset_tool);
    ("masc_start", with_semantic_flags ~mcp_context_required:true broadcast_tool);
    ("masc_task_history", read_state_tool);
    ("masc_add_task", add_task_tool);
    ("masc_batch_add_tasks", add_task_tool);
    ("masc_update_priority", complete_task_tool);
    ("masc_heartbeat", broadcast_tool);
    ("masc_goal_list", read_state_tool);
    ("masc_goal_upsert", broadcast_tool);
    ("masc_goal_transition", broadcast_tool);
    ("masc_plan_init", broadcast_tool);
    ("masc_plan_update", broadcast_tool);
    ("masc_keeper_list", read_state_tool);
    ("masc_keeper_status", read_state_tool);
    ("masc_keeper_sandbox_start", broadcast_tool);
    ("masc_keeper_sandbox_stop", mutating_tool);
    ("masc_keeper_create_from_persona", broadcast_tool);
    ("masc_keeper_msg", broadcast_tool);
    ("masc_keeper_msg_result", read_state_tool);
    ("masc_keeper_msg_cancel", broadcast_tool);
    ("masc_keeper_msg_queue", read_state_tool);
    ("masc_keeper_persona_audit", read_state_tool);
    ("masc_keeper_sandbox_status", read_state_tool);
    ("masc_keeper_waiting_inventory", read_state_tool);
    ("masc_keeper_up", broadcast_tool);
    ("masc_keeper_down", mutating_tool);
    ("masc_keeper_compact", broadcast_tool);
    ("masc_keeper_clear", mutating_tool);
    ("masc_keeper_reset", mutating_tool);
    ("masc_plan_get_task", read_state_tool);
    ("masc_plan_clear_task", broadcast_tool);
    ("masc_note_add", broadcast_tool);
    ("masc_deliver", broadcast_tool);
    ("masc_config", read_state_tool);
    ("masc_check", read_state_tool);
    ("masc_web_search", read_state_tool);
    ("masc_web_fetch", read_state_tool);
    ("masc_agent_fitness", read_state_tool);
    ("masc_agent_timeline", read_state_tool);
    ("masc_get_metrics", read_state_tool);
    ("masc_operator_snapshot", read_state_tool);
    ("masc_operator_digest", read_state_tool);
    ("masc_operator_confirm", broadcast_tool);
    ("masc_persona_list", read_state_tool);
    ("masc_persona_create", broadcast_tool);
    ("masc_persona_update", broadcast_tool);
    ("masc_persona_delete", broadcast_tool);
    ("masc_runtime_verify", read_state_tool);
    ("masc_runtime_ollama_probe", read_state_tool);
    ("masc_cleanup_zombies", broadcast_tool);
    ("masc_board_hearths", read_state_tool);
    ("masc_board_search", read_state_tool);
    ("masc_board_profile", read_state_tool);
    ("masc_board_stats", read_state_tool);
    ("masc_board_sub_board_list", read_state_tool);
    ("masc_board_sub_board_get", read_state_tool);
    ("masc_board_post", broadcast_tool);
    ("masc_board_comment", broadcast_tool);
    ("masc_board_vote", broadcast_tool);
    ("masc_board_comment_vote", broadcast_tool);
    ("masc_board_reaction", broadcast_tool);
    ("masc_board_sub_board_create", broadcast_tool);
    ("masc_board_sub_board_update", broadcast_tool);
    ("masc_board_sub_board_delete", broadcast_tool);
    ("masc_board_cleanup", mutating_tool);
    ("masc_board_delete", mutating_tool);
    ("masc_tool_stats", read_state_tool);
    ("masc_pause", broadcast_tool);
    ("masc_resume", broadcast_tool);
    ("masc_run_get", broadcast_tool);
    ("masc_run_list", read_state_tool);
    ("masc_run_init", broadcast_tool);
    ("masc_run_plan", broadcast_tool);
    ( "keeper_tasks_list",
      hidden_runtime_tool
        "Keeper task-list runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "keeper_task_claim",
      hidden_runtime_tool
        "Keeper task-claim runtime tool; callable but hidden from the public MCP schema surface."
        claim_task_tool );
    ( "keeper_task_done",
      hidden_runtime_tool
        "Keeper task-completion runtime tool; callable but hidden from the public MCP schema surface."
        complete_task_tool );
    ( "keeper_board_search",
      hidden_runtime_tool
        "Keeper board-search runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "keeper_tools_list",
      hidden_runtime_tool
        "Keeper tool-list runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "tool_execute",
      hidden_runtime_tool
        "Typed command-execution runtime tool; callable but hidden from the public MCP schema surface."
        mutating_tool );
    ( "tool_read_file",
      hidden_runtime_tool
        "Structured file-read runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "tool_search_files",
      hidden_runtime_tool
        "Structured code-search runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ("sidecar", { mutating_tool with visibility = Hidden });
  ]

(* ================================================================ *)
(* Runtime metadata table (O(1) lookup, seeded from explicit list)  *)
(* ================================================================ *)

let metadata_table : (string, metadata) Hashtbl.t = Hashtbl.create 256
let () = List.iter (fun (n, m) -> Hashtbl.replace metadata_table n m) explicit_metadata

let register_metadata name (meta : metadata) =
  Hashtbl.replace metadata_table name meta

let registered_metadata name =
  Hashtbl.find_opt metadata_table name

(* ================================================================ *)
(* Public MCP surface — delegates to Tool_catalog_surfaces (SSOT)   *)
(* ================================================================ *)

(* Delegate to surfaces sub-module *)
let public_mcp_tools = Tool_catalog_surfaces.public_mcp_surface_tools

let public_mcp_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  List.iter (fun name -> Hashtbl.replace tbl name ())
    Tool_catalog_surfaces.public_mcp_surface_tools;
  (* MASC_PUBLIC_TOOLS_EXTRA: comma-separated tool names to add at runtime.
     Example: MASC_PUBLIC_TOOLS_EXTRA=masc_board_search,masc_pause *)
  (match Env_config.Tools.public_tools_extra_opt () with
   | Some raw ->
       String.split_on_char ',' raw
       |> List.iter (fun s ->
              let name = String.trim s in
              if not (String.equal name "") then Hashtbl.replace tbl name ())
   | None -> ());
  tbl

let is_public_mcp name = Hashtbl.mem public_mcp_set name

(* ================================================================ *)
(* Metadata lookup                                                  *)
(* ================================================================ *)

let implementation_status_to_string = function
  | Real -> "real"
  | Adapter -> "adapter"
  | Simulation -> "simulation"
  | Placeholder -> "placeholder"

let implementation_allows_public_visibility = function
  | Real | Adapter -> true
  | Simulation | Placeholder -> false

let metadata name =
  match Hashtbl.find_opt metadata_table name with
  | Some meta -> meta
  | None ->
    if is_public_mcp name
    then default_metadata
    else
      (* External MCP discovery remains an explicit public-surface contract.
         It must not be reused as Keeper authorization or model visibility. *)
      { default_metadata with
        visibility = Hidden
      ; allow_direct_call_when_hidden = true
      ; reason = Some "Not on the external MCP discovery surface."
      }

let implementation_status name =
  let meta = metadata name in
  meta.implementation_status

let canonical_tool_name name =
  match (metadata name).canonical_name with
  | Some canonical_name -> canonical_name
  | None -> name

let is_placeholder name =
  match implementation_status name with
  | Placeholder -> true
  | Real | Adapter | Simulation -> false

let is_visible ?(include_hidden = false) name =
  let meta = metadata name in
  match meta.visibility with
  | Hidden when include_hidden -> true
  | Hidden when placeholder_tools_enabled () && is_placeholder name -> true
  | Hidden -> false
  | Default -> implementation_allows_public_visibility meta.implementation_status

let visibility_to_string = function
  | Default -> "default"
  | Hidden -> "hidden"

let lifecycle_to_string = function
  | Active -> "active"

(* ================================================================ *)
(* JSON metadata helpers                                            *)
(* ================================================================ *)

let metadata_to_fields name =
  let meta = metadata name in
  (* The per-actor "surfaces" field was dropped in the surface-cut refactor.
     External MCP discovery is represented by [is_public_mcp]; Keeper model
     visibility is descriptor-owned and deliberately independent. *)
  let base =
    [
      ("visibility", `String (visibility_to_string meta.visibility));
      ("lifecycle", `String (lifecycle_to_string meta.lifecycle));
      ("implementationStatus", `String (implementation_status_to_string meta.implementation_status));
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
  let with_reason =
    match meta.reason with
    | Some reason -> ("reason", `String reason) :: with_replacement
    | None -> with_replacement
  in
  let with_mcp_context_required =
    match meta.mcp_context_required with
    | Some value -> ("mcpContextRequired", `Bool value) :: with_reason
    | None -> with_reason
  in
  with_mcp_context_required

let public_contract_fields name =
  let meta = metadata name in
  let base =
    [
      ( "implementationStatus",
        `String (implementation_status_to_string meta.implementation_status) );
    ]
  in
  let with_mcp_context_required =
    match meta.mcp_context_required with
    | Some value -> ("mcpContextRequired", `Bool value) :: base
    | None -> base
  in
  match meta.canonical_name with
  | Some canonical_name -> ("canonicalName", `String canonical_name) :: with_mcp_context_required
  | None -> with_mcp_context_required

let allow_direct_call name =
  let meta = metadata name in
  match meta.visibility with
  | Default -> true
  | Hidden -> meta.allow_direct_call_when_hidden
