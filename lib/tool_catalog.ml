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

(** Tool_catalog — Visibility and lifecycle metadata for MCP tools.

    Central registry for tool access control:
    - Visibility: Default (public) vs Hidden (internal-only)
    - Lifecycle: Active, Deprecated, Placeholder
    - Surface: Canonical per-surface tool name membership SSOT

    Sub-modules (private):
    - Tool_catalog_surfaces: surface type, canonical tool lists, keeper-internal
    - Tool_catalog_inference: typed-name -> effect_domain / tool_group

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

(* effect_domain / tool_group live in Tool_catalog_inference. Re-export the
   variants here so [tool_catalog.mli] keeps the same public constructors. *)
include (Tool_catalog_inference : sig
  type effect_domain = Tool_catalog_inference.effect_domain =
    | Read_only
    | Masc_coordination
    | Playground_write
    | Main_worktree_write

  type tool_group = Tool_catalog_inference.tool_group =
    | Board
    | Knowledge
    | Tasks
    | Voice
    | Filesystem
    | Masc_board
    | Masc_keeper
    | Masc_plan
    | Masc_worktree
    | Masc_code
    | Masc_autoresearch
    | Masc_agent
    | Masc_core
end)

include (Tool_catalog_surfaces : sig
  type surface = Tool_catalog_surfaces.surface =
    | Public_mcp | Spawned_agent | Local_worker | Session_min
    | Admin | Keeper_internal | Keeper_denied | System_internal
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
  required_permission : Masc_domain.permission option;
  effect_domain : effect_domain option;
  requires_actor_binding : bool option;
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
    effect_domain = None;
    requires_actor_binding = None;
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
    effect_domain = None;
    requires_actor_binding = None;
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
    effect_domain = None;
    requires_actor_binding = None;
  }

let with_semantic_flags ?readonly ?destructive ?idempotent ?effect_domain
    ?requires_actor_binding meta =
  {
    meta with
    readonly =
      (match readonly with Some value -> Some value | None -> meta.readonly);
    destructive =
      (match destructive with Some value -> Some value | None -> meta.destructive);
    idempotent =
      (match idempotent with Some value -> Some value | None -> meta.idempotent);
    effect_domain =
      (match effect_domain with
      | Some value -> Some value
      | None -> meta.effect_domain);
    requires_actor_binding =
      (match requires_actor_binding with
      | Some value -> Some value
      | None -> meta.requires_actor_binding);
  }

let readonly_tool =
  with_semantic_flags ~readonly:true ~idempotent:true
    ~effect_domain:Read_only default_metadata

let destructive_tool =
  with_semantic_flags ~destructive:true default_metadata

let masc_coordination_tool =
  with_semantic_flags ~effect_domain:Masc_coordination default_metadata

let actor_bound_masc_coordination_tool =
  with_semantic_flags ~requires_actor_binding:true masc_coordination_tool

(* ================================================================ *)
(* Explicit metadata registry                                       *)
(* ================================================================ *)

let explicit_metadata : (string * metadata) list =
  [
    ( "masc_operator_judgment_write",
      hidden_active
        "Internal operator-judge write path hidden from the default tool list; use for operator judgment experiments and keeper automation." );
    (* Physically removed: masc_interrupt, masc_approve, masc_reject,
       masc_pending_interrupts, masc_branch (masc-checkpoint CLI removed,
       #4709/#4734), operator_judgment_latest, hat_wear, hat_status,
       encryption_*, generate_key, tempo*, cost_log, cost_report (#4709/#4757). *)
    (* Semantic annotations for governance risk classification. *)
    ("masc_status", readonly_tool);
    ("masc_tasks", readonly_tool);
    ("masc_messages", readonly_tool);
    ("masc_who", readonly_tool);
    ("masc_agents", readonly_tool);
    ( "masc_agent_card",
      { readonly_tool with required_permission = Some Masc_domain.CanReadState } );
    ("masc_dashboard", readonly_tool);
    ("masc_board_list", readonly_tool);
    ("masc_board_get", readonly_tool);
    ( "masc_board_curation_read",
      { readonly_tool with required_permission = Some Masc_domain.CanReadState } );
    ( "masc_board_curation_submit",
      { actor_bound_masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ("masc_tool_help", readonly_tool);
    ("masc_keeper_list", readonly_tool);
    ("masc_keeper_status", readonly_tool);
    ("masc_keeper_persona_audit", readonly_tool);
    ("masc_plan_get", readonly_tool);
    ("masc_worktree_list", readonly_tool);
    ( "masc_join",
      { actor_bound_masc_coordination_tool with required_permission = Some Masc_domain.CanJoin } );
    ( "masc_leave",
      { actor_bound_masc_coordination_tool with required_permission = Some Masc_domain.CanLeave } );
    ("masc_claim_next", actor_bound_masc_coordination_tool);
    ("masc_transition", actor_bound_masc_coordination_tool);
    ("masc_plan_set_task", actor_bound_masc_coordination_tool);
    ( "masc_broadcast",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_messages",
      { readonly_tool with required_permission = Some Masc_domain.CanReadState } );
    ( "masc_who",
      { readonly_tool with required_permission = Some Masc_domain.CanReadState } );
    ( "channel_gate",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_portal_open",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanOpenPortal } );
    ( "masc_portal_close",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanOpenPortal } );
    ( "masc_portal_send",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanSendPortal } );
    ( "masc_room_status",
      hidden_active ~canonical_name:"masc_status" ~replacement:"masc_status"
        "Managed-agent compatibility alias. Prefer masc_status for canonical namespace state reads." );
    ( "masc_list_tasks",
      hidden_active ~canonical_name:"masc_tasks" ~replacement:"masc_tasks"
        "Managed-agent compatibility alias. Prefer masc_tasks for canonical backlog reads." );
    ( "masc_claim_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=claim)." );
    ( "masc_set_current_task",
      hidden_active ~canonical_name:"masc_plan_set_task" ~replacement:"masc_plan_set_task"
        "Managed-agent compatibility alias that binds current_task. Prefer masc_plan_set_task." );
    ( "masc_complete_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=done)." );
    ( "masc_release_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=release)." );
    ( "masc_cancel_task",
      hidden_active ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Managed-agent compatibility alias for masc_transition(action=cancel)." );
    (* masc_run_get, masc_run_list: migrated to Tool_spec.register (tool_run.ml) *)
    ("masc_execute_dry_run", readonly_tool);
    ( "masc_admin_cleanup",
      with_semantic_flags ~destructive:true
        (hidden_active "Administrative cleanup mutates persisted namespace state and should be treated as destructive.") );
    ( "masc_admin_reset",
      with_semantic_flags ~destructive:true
        (hidden_active "Administrative reset clears namespace state and should be treated as destructive.") );
    ( "masc_gc_force",
      with_semantic_flags ~destructive:true
        (hidden_active "Forced garbage collection removes persisted artifacts and should be treated as destructive.") );
    ( "masc_room_delete",
      with_semantic_flags ~destructive:true
        (hidden_active "Namespace deletion removes persisted state and should be treated as destructive.") );
    ( "masc_force_leave",
      with_semantic_flags ~destructive:true
        (hidden_active "Forced membership removal mutates namespace state and should be treated as destructive.") );
    ( "masc_operator_action",
      with_semantic_flags ~destructive:true
        (hidden_active "Operator actions can execute privileged side effects and should be treated as destructive.") );
    ( "masc_set_param",
      {
        (with_semantic_flags ~destructive:true
           (hidden_active
              "Internal HTTP runtime-parameter mutation route; hidden from the public tool surface."))
        with
        required_permission = Some Masc_domain.CanAdmin;
      } );
    ( "masc_execute",
      with_semantic_flags ~destructive:true
        (hidden_active "Direct execution can apply privileged side effects and should be treated as destructive.") );
    ("masc_tool_grant", destructive_tool);
    ("masc_tool_revoke", destructive_tool);
    ( "masc_keeper_reset",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_keeper_compact",
      { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_keeper_clear",
      with_semantic_flags ~destructive:true
        { masc_coordination_tool with required_permission = Some Masc_domain.CanBroadcast } );
    ( "masc_operation_stop",
      destructive_tool );
    ( "masc_operation_pause",
      { default_metadata with destructive = Some false } );
    (* WebRTC tools: deprecated as MCP tools but still used as HTTP
       signaling endpoints in server_h2_gateway.ml — kept for now. *)
    ("masc_webrtc_offer", deprecated "Pruned from all surfaces in #4999");
    ("masc_webrtc_answer", deprecated "Pruned from all surfaces in #4999");
    ( "sidecar",
      {
        destructive_tool with
        visibility = Hidden;
        required_permission = Some Masc_domain.CanBroadcast;
        effect_domain = Some Masc_coordination;
      } );
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
let keeper_internal_replacement = Tool_catalog_surfaces.keeper_internal_replacement

let public_mcp_tools = Tool_catalog_surfaces.public_mcp_surface_tools

let keeper_internal_metadata name =
  let replacement = keeper_internal_replacement name in
  let implementation_status =
    match replacement with
    | Some _ -> Adapter
    | None -> Real
  in
  let meta =
    hidden_active
    ?canonical_name:replacement
    ?replacement
    ~allow_direct_call_when_hidden:false
    ~implementation_status
    "Keeper-internal tool. Use the keeper runtime or the public MASC equivalent when available."
  in
  {
    meta with
    required_permission = Some Masc_domain.CanBroadcast;
    requires_actor_binding = Some true;
  }

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

let full_surface_override () = Env_config.Tools.full_surface_enabled ()

(* ================================================================ *)
(* Metadata lookup                                                  *)
(* ================================================================ *)

let implementation_status_to_string = function
  | Real -> "real"
  | Adapter -> "adapter"
  | Simulation -> "simulation"
  | Placeholder -> "placeholder"

(* effect_domain_to_string / tool_group_to_string: re-export from
   Tool_catalog_inference to keep one definition. *)
let effect_domain_to_string = Tool_catalog_inference.effect_domain_to_string
let tool_group_to_string = Tool_catalog_inference.tool_group_to_string

let implementation_allows_public_visibility = function
  | Real | Adapter -> true
  | Simulation | Placeholder -> false

(* Typed-name inference (effect_domain / tool_group) lives in
   Tool_catalog_inference. Re-export the public entry points so the
   facade contract in [tool_catalog.mli] is unchanged. *)
let inferred_effect_domain = Tool_catalog_inference.inferred_effect_domain
let tool_group = Tool_catalog_inference.tool_group


let attach_inferred_effect_domain name (meta : metadata) =
  match meta.effect_domain with
  | Some _ -> meta
  | None -> { meta with effect_domain = inferred_effect_domain name }

let metadata name =
  (* Hot path: called from MCP execute, tool list, OAS bridge, capability
     registry, keeper guards, help registry, governance risk, etc.  Cache
     surface-membership checks per call rather than re-querying. *)
  let is_system_internal =
    Tool_catalog_surfaces.is_on_surface System_internal name
  in
  let base =
    match Hashtbl.find_opt metadata_table name with
    | Some meta -> meta
    | None ->
      if is_public_mcp name then default_metadata
      else if Tool_catalog_surfaces.is_on_surface Keeper_internal name then
        keeper_internal_metadata name
      else if is_system_internal then
        { default_metadata with
          visibility = Hidden;
          allow_direct_call_when_hidden = true;
          reason = Some "System-internal tool; callable but not listed in tools/list." }
      else
        (* Non-public, non-explicit tools are internal: hidden from tools/list
           but callable via tools/call (tool_allowed_in_profile uses include_hidden). *)
        { default_metadata with
          visibility = Hidden;
          allow_direct_call_when_hidden = true;
          reason = Some "Internal tool; not on public MCP surface." }
  in
  let with_surface_visibility =
    if is_system_internal then
    (* Surface membership is the canonical "hidden but callable" contract for
       system-internal tools, even when a tool also carries explicit metadata
       for semantic hints like readonly/destructive. *)
      {
        base with
        visibility = Hidden;
        allow_direct_call_when_hidden = true;
        reason =
          (match base.reason with
          | Some _ -> base.reason
          | None ->
              Some
                "System-internal tool; callable but not listed in tools/list.");
      }
    else
      base
  in
  attach_inferred_effect_domain name with_surface_visibility

let implementation_status name =
  let meta = metadata name in
  meta.implementation_status

let effect_domain name =
  let meta = metadata name in
  meta.effect_domain

let requires_actor_binding name =
  match (metadata name).requires_actor_binding with
  | Some value -> value
  | None -> false

let is_main_worktree_boundary_exempt name =
  match effect_domain name with
  | Some Read_only | Some Masc_coordination | Some Playground_write -> Some true
  | Some Main_worktree_write -> Some false
  | None -> None

let canonical_tool_name name =
  match (metadata name).canonical_name with
  | Some canonical_name -> canonical_name
  | None -> name

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
  List.filter (fun (_name, meta) -> (=) meta.lifecycle Deprecated) explicit_metadata

(* ================================================================ *)
(* JSON metadata helpers                                            *)
(* ================================================================ *)

let metadata_to_fields name =
  let meta = metadata name in
  let surfaces =
    Tool_catalog_surfaces.surfaces_for_tool name
    |> List.map (fun s -> `String (Tool_catalog_surfaces.surface_to_string s))
  in
  let base =
    [
      ("visibility", `String (visibility_to_string meta.visibility));
      ("lifecycle", `String (lifecycle_to_string meta.lifecycle));
      ("implementationStatus", `String (implementation_status_to_string meta.implementation_status));
      ("surfaces", `List surfaces);
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
  let with_effect_domain =
    match meta.effect_domain with
    | Some effect_domain ->
        ("effectDomain", `String (effect_domain_to_string effect_domain))
        :: with_reason
    | None -> with_reason
  in
  let with_tool_group =
    match tool_group name with
    | Some group ->
        ("toolGroup", `String (tool_group_to_string group)) :: with_effect_domain
    | None -> with_effect_domain
  in
  let with_actor_binding =
    match meta.requires_actor_binding with
    | Some value -> ("requiresActorBinding", `Bool value) :: with_tool_group
    | None -> with_tool_group
  in
  match meta.required_permission with
  | Some permission ->
      ("requiredPermission", `String (Masc_domain.permission_to_string permission))
      :: with_actor_binding
  | None -> with_actor_binding

let public_contract_fields name =
  let meta = metadata name in
  let base =
    [
      ( "implementationStatus",
        `String (implementation_status_to_string meta.implementation_status) );
    ]
  in
  let with_effect_domain =
    match meta.effect_domain with
    | Some effect_domain ->
        ("effectDomain", `String (effect_domain_to_string effect_domain))
        :: base
    | None -> base
  in
  let with_actor_binding =
    match meta.requires_actor_binding with
    | Some value -> ("requiresActorBinding", `Bool value) :: with_effect_domain
    | None -> with_effect_domain
  in
  match meta.canonical_name with
  | Some canonical_name -> ("canonicalName", `String canonical_name) :: with_actor_binding
  | None -> with_actor_binding

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
