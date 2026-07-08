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

    Sub-modules (private):
    - Tool_catalog_surfaces: surface type and canonical tool lists
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

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

(* effect_domain lives in Tool_catalog_inference. Re-export the variants here
   so [tool_catalog.mli] keeps the same public constructors. *)
include (Tool_catalog_inference : sig
  type effect_domain = Tool_catalog_inference.effect_domain =
    | Read_only
    | Masc_workspace
    | Playground_write
    | Host_repo_write
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
  mcp_context_required : bool option;
  destructive : bool option;
  idempotent : bool option;
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
    mcp_context_required = None;
    destructive = None;
    idempotent = None;
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
    destructive = None;
    idempotent = None;
    effect_domain = None;
    requires_actor_binding = None;
  }

let with_semantic_flags ?readonly ?mcp_context_required
    ?destructive ?idempotent ?effect_domain ?requires_actor_binding meta =
  {
    meta with
    readonly =
      (match readonly with Some value -> Some value | None -> meta.readonly);
    mcp_context_required =
      (match mcp_context_required with
      | Some value -> Some value
      | None -> meta.mcp_context_required);
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

let masc_workspace_tool =
  with_semantic_flags ~effect_domain:Masc_workspace default_metadata

let actor_bound_masc_workspace_tool =
  with_semantic_flags ~requires_actor_binding:true masc_workspace_tool

let read_state_tool = readonly_tool
let broadcast_tool = masc_workspace_tool
let actor_broadcast_tool = actor_bound_masc_workspace_tool
let add_task_tool = masc_workspace_tool
let claim_task_tool = actor_bound_masc_workspace_tool
let complete_task_tool = actor_bound_masc_workspace_tool
let reset_tool = destructive_tool

let hidden_runtime_tool reason meta =
  {
    meta with
    visibility = Hidden;
    allow_direct_call_when_hidden = true;
    reason = Some reason;
  }

let static_mcp_context_tool_names =
  [ "masc_start"
  ; "masc_broadcast"
  ; "masc_messages"
  ; "masc_session"
  ]

let static_destructive_tool_names =
  [ "tool_execute"
  ; "tool_edit_file"
  ; "tool_write_file"
  ; "shell_exec"
  ]

let force_true_if_member name names current =
  if List.mem name names then Some true else current

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
    (* Semantic annotations for governance risk classification. *)
    ("masc_status", read_state_tool);
    ("masc_tasks", read_state_tool);
    ("masc_messages", read_state_tool);
    ("masc_agent_card", read_state_tool);
    ("masc_dashboard", read_state_tool);
    ("masc_board_list", read_state_tool);
    ("masc_board_post_get", read_state_tool);
    ("masc_board_curation_read", read_state_tool);
    ( "masc_board_curation_submit",
      actor_broadcast_tool );
    ("masc_tool_help", read_state_tool);
    ("masc_plan_get", broadcast_tool);
    ("masc_transition", complete_task_tool);
    ("masc_plan_set_task", actor_broadcast_tool);
    ("masc_broadcast", broadcast_tool);
    ("channel_gate", broadcast_tool);
    (* Run schemas register from tool_run.ml; catalog still owns early auth metadata.
       RFC-0182: 7 dead admin tools (masc_execute_dry_run, masc_admin_cleanup,
       masc_admin_reset, masc_gc_force, masc_workspace_delete, masc_force_unbind,
       masc_execute) removed — no dispatch path, no schema, no caller. *)
    ( "masc_operator_action",
      with_semantic_flags ~destructive:true
        (hidden_active "Operator actions can execute privileged side effects and should be treated as destructive.") );
    ( "masc_set_param",
      with_semantic_flags ~destructive:true
        (hidden_active
           "Internal HTTP runtime-parameter mutation route; hidden from the public tool surface.") );
    (* Catalog-owned permissions for split/lazily registered tool modules. *)
    ("masc_reset", reset_tool);
    ("masc_start", broadcast_tool);
    ("masc_task_history", read_state_tool);
    ("masc_add_task", add_task_tool);
    ("masc_batch_add_tasks", add_task_tool);
    ("masc_update_priority", complete_task_tool);
    ("masc_heartbeat", actor_broadcast_tool);
    ("masc_goal_list", read_state_tool);
    ("masc_goal_upsert", broadcast_tool);
    ("masc_goal_transition", broadcast_tool);
    ("masc_goal_verify", broadcast_tool);
    ("masc_plan_init", broadcast_tool);
    ("masc_plan_update", broadcast_tool);
    ("masc_keeper_list", read_state_tool);
    ("masc_keeper_status", read_state_tool);
    ("masc_keeper_up", broadcast_tool);
    ( "masc_keeper_down",
      with_semantic_flags ~destructive:true ~effect_domain:Masc_workspace
        default_metadata );
    ("masc_plan_get_task", read_state_tool);
    ("masc_plan_clear_task", actor_broadcast_tool);
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
    ("masc_operator_confirm", actor_broadcast_tool);
    ("masc_surface_audit", read_state_tool);
    ("masc_persona_list", read_state_tool);
    ("masc_persona_create", broadcast_tool);
    ("masc_persona_update", broadcast_tool);
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
    ("masc_board_cleanup", destructive_tool);
    ("masc_board_delete", destructive_tool);
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
        destructive_tool );
    ( "tool_read_file",
      hidden_runtime_tool
        "Structured file-read runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "tool_search_files",
      hidden_runtime_tool
        "Structured code-search runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "sidecar",
      {
        destructive_tool with
        visibility = Hidden;
        effect_domain = Some Masc_workspace;
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

let full_surface_override () = Env_config.Tools.full_surface_enabled ()

(* ================================================================ *)
(* Metadata lookup                                                  *)
(* ================================================================ *)

let implementation_status_to_string = function
  | Real -> "real"
  | Adapter -> "adapter"
  | Simulation -> "simulation"
  | Placeholder -> "placeholder"

(* effect_domain_to_string: re-export from Tool_catalog_inference to keep one
   definition. *)
let effect_domain_to_string = Tool_catalog_inference.effect_domain_to_string

let implementation_allows_public_visibility = function
  | Real | Adapter -> true
  | Simulation | Placeholder -> false

(* Typed-name inference (effect_domain) lives in Tool_catalog_inference.
   Re-export the public entry point so the facade contract in
   [tool_catalog.mli] is unchanged. *)
let inferred_effect_domain = Tool_catalog_inference.inferred_effect_domain


let attach_inferred_effect_domain name (meta : metadata) =
  match meta.effect_domain with
  | Some _ -> meta
  | None -> { meta with effect_domain = inferred_effect_domain name }

let attach_static_capabilities name (meta : metadata) =
  {
    meta with
    mcp_context_required =
      force_true_if_member
        name
        static_mcp_context_tool_names
        meta.mcp_context_required;
    destructive =
      force_true_if_member name static_destructive_tool_names meta.destructive;
  }

let metadata name =
  (* Hot path: called from MCP execute, tool list, OAS bridge, capability
     registry, help registry, governance risk, etc.  Cache
     surface-membership checks per call rather than re-querying. *)
  let is_system_internal =
    Tool_catalog_surfaces.is_system_internal_hidden name
  in
  let base =
    match Hashtbl.find_opt metadata_table name with
    | Some meta -> meta
    | None ->
      if is_public_mcp name then default_metadata
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
    (* System-internal membership is the canonical "hidden but callable"
       contract for these tools, even when a tool also carries explicit
       metadata with Default visibility for semantic hints like
       readonly/destructive — that Default is overridden to Hidden here. *)
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
  with_surface_visibility
  |> attach_inferred_effect_domain name
  |> attach_static_capabilities name

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
  (* The per-actor "surfaces" field was dropped in the surface-cut refactor:
     the [surface] type that produced it (Tool_catalog_surfaces.surfaces_for_tool)
     was deleted. Visibility is now expressed by the [visibility] field +
     is_public_mcp / is_system_internal_hidden projections, not an actor list. *)
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
  let with_effect_domain =
    match meta.effect_domain with
    | Some effect_domain ->
        ("effectDomain", `String (effect_domain_to_string effect_domain))
        :: with_reason
    | None -> with_reason
  in
  (* The "toolGroup" field was dropped in the surface-cut refactor: the
     [tool_group] display classifier was deleted. *)
  let with_mcp_context_required =
    match meta.mcp_context_required with
    | Some value -> ("mcpContextRequired", `Bool value) :: with_effect_domain
    | None -> with_effect_domain
  in
  let with_actor_binding =
    match meta.requires_actor_binding with
    | Some value -> ("requiresActorBinding", `Bool value) :: with_mcp_context_required
    | None -> with_mcp_context_required
  in
  with_actor_binding

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
  let with_mcp_context_required =
    match meta.mcp_context_required with
    | Some value -> ("mcpContextRequired", `Bool value) :: with_actor_binding
    | None -> with_actor_binding
  in
  match meta.canonical_name with
  | Some canonical_name -> ("canonicalName", `String canonical_name) :: with_mcp_context_required
  | None -> with_mcp_context_required

let allow_direct_call name =
  let meta = metadata name in
  match meta.visibility with
  | Default -> true
  | Hidden -> meta.allow_direct_call_when_hidden
