(** Tool_catalog — Visibility, lifecycle, and tier metadata for MCP tools.

    Central registry for tool access control:
    - Visibility: Default (public) vs Hidden (internal-only)
    - Lifecycle: Active, Deprecated, Placeholder
    - Tier: Essential (~20) < Standard (~50) < Full (all)
    - Surface: Canonical per-surface tool name membership SSOT

    Sub-modules (private):
    - Tool_catalog_surfaces: surface type, canonical tool lists, keeper-internal
    - Tool_catalog_tiers: tier type, essential/standard tool lists

    @since 2.188.0 — Decomposed from monolithic tool_catalog.ml *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

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

(* Re-export tier type and surface type from sub-modules *)
include (Tool_catalog_tiers : sig
  type tier = Tool_catalog_tiers.tier = Essential | Standard | Full
end)

include (Tool_catalog_surfaces : sig
  type surface = Tool_catalog_surfaces.surface =
    | Public_mcp | Spawned_agent | Local_worker | Session_min
    | Admin | Keeper_internal | Keeper_denied
end)

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
  required_permission : Types.permission option;
}

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
    destructive = None;
    idempotent = None;
    required_permission = None;
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
    required_permission = None;
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
    required_permission = None;
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
    required_permission = None;
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

(* ================================================================ *)
(* Explicit metadata registry                                       *)
(* ================================================================ *)

let explicit_metadata : (string * metadata) list =
  [
    ( "masc_operator_judgment_write",
      hidden_active
        "Internal operator-judge write path hidden from the default tool list; use for operator judgment experiments and keeper automation." );
    ( "masc_operator_judgment_latest",
      hidden_active
        "Internal operator-judge read path hidden from the default tool list; use for operator judgment experiments and keeper automation." );
    (* Dead features removed: hat (2), encryption (4), tempo (5).
       See #4709 for audit. Files deleted: tool_hat.ml, tool_encryption.ml, tool_tempo.ml. *)
    (* Broken tools: shell out to CLI binaries unavailable at runtime.
       masc-cost: buildable from bin/masc_cost.ml but not guaranteed to be
       present in runtime images or on PATH.
       masc-checkpoint: removed from codebase (refactor #102).
       Deprecated 2026-04-03. See #4709, #4734. *)
    ("masc_cost_log",
     deprecated ~implementation_status:Real
       "Shells out to masc-cost CLI which may be unavailable in the runtime environment or missing from PATH.");
    ("masc_cost_report",
     deprecated ~implementation_status:Real
       "Shells out to masc-cost CLI which may be unavailable in the runtime environment or missing from PATH.");
    ("masc_interrupt",
     deprecated ~implementation_status:Real
       "Shells out to masc-checkpoint CLI which was removed from the codebase. Always fails at runtime.");
    ("masc_approve",
     deprecated ~implementation_status:Real
       "Shells out to masc-checkpoint CLI which was removed from the codebase. Always fails at runtime.");
    ("masc_reject",
     deprecated ~implementation_status:Real
       "Shells out to masc-checkpoint CLI which was removed from the codebase. Always fails at runtime.");
    ("masc_pending_interrupts",
     deprecated ~implementation_status:Real
       "Shells out to masc-checkpoint CLI which was removed from the codebase. Always fails at runtime.");
    ("masc_branch",
     deprecated ~implementation_status:Real
       "Shells out to masc-checkpoint CLI which was removed from the codebase. Always fails at runtime.");
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
    (* masc_run_get, masc_run_list: migrated to Tool_spec.register (tool_run.ml) *)
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
    ( "masc_set_param",
      {
        (with_semantic_flags ~destructive:true
           (hidden_active
              "Internal HTTP runtime-parameter mutation route; hidden from the public tool surface."))
        with
        required_permission = Some Types.CanAdmin;
      } );
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

(* ================================================================ *)
(* Runtime metadata table (O(1) lookup, seeded from explicit list)  *)
(* ================================================================ *)

let metadata_table : (string, metadata) Hashtbl.t = Hashtbl.create 256
let () = List.iter (fun (n, m) -> Hashtbl.replace metadata_table n m) explicit_metadata

let register_metadata name (meta : metadata) =
  Hashtbl.replace metadata_table name meta

(* ================================================================ *)
(* Public MCP surface — delegates to Tool_catalog_surfaces (SSOT)   *)
(* ================================================================ *)

(* Delegate to surfaces sub-module *)
let keeper_internal_set = Tool_catalog_surfaces.keeper_internal_set

let keeper_internal_replacement = Tool_catalog_surfaces.keeper_internal_replacement

let public_mcp_tools = Tool_catalog_surfaces.public_mcp_surface_tools

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
  List.iter (fun name -> Hashtbl.replace tbl name ())
    Tool_catalog_surfaces.public_mcp_surface_tools;
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

(* ================================================================ *)
(* Re-export: Tier system (from Tool_catalog_tiers)                 *)
(* ================================================================ *)

let essential_tools = Tool_catalog_tiers.essential_tools
let standard_tools = Tool_catalog_tiers.standard_tools
let tier_to_string = Tool_catalog_tiers.tier_to_string
let tier_of_string = Tool_catalog_tiers.tier_of_string
let tool_tier = Tool_catalog_tiers.tool_tier
let is_in_tier = Tool_catalog_tiers.is_in_tier
let tier_tool_count = Tool_catalog_tiers.tier_tool_count

(* ================================================================ *)
(* JSON metadata helpers                                            *)
(* ================================================================ *)

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
  let with_reason =
    match meta.reason with
    | Some reason -> ("reason", `String reason) :: with_replacement
    | None -> with_replacement
  in
  match meta.required_permission with
  | Some permission ->
      ("requiredPermission", `String (Types.show_permission permission))
      :: with_reason
  | None -> with_reason

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

(* ================================================================ *)
(* Re-export: Surface system (from Tool_catalog_surfaces)           *)
(* ================================================================ *)

let tools_for_surface = Tool_catalog_surfaces.tools_for_surface
let all_surfaces = Tool_catalog_surfaces.all_surfaces
let is_on_surface = Tool_catalog_surfaces.is_on_surface
let surface_to_string = Tool_catalog_surfaces.surface_to_string
