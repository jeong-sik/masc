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
  reason : string option;
  allow_direct_call_when_hidden : bool;
  readonly : bool option;
  mcp_context_required : bool option;
  idempotent : bool option;
  required_permission : Masc_domain.permission;
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

let default_metadata ~required_permission =
  {
    visibility = Default;
    lifecycle = Active;
    implementation_status = Real;
    reason = None;
    allow_direct_call_when_hidden = false;
    readonly = None;
    mcp_context_required = None;
    idempotent = None;
    required_permission;
  }

let hidden_active ?(allow_direct_call_when_hidden = true)
    ?(implementation_status = Real) ~required_permission reason =
  {
    visibility = Hidden;
    lifecycle = Active;
    implementation_status;
    reason = Some reason;
    allow_direct_call_when_hidden;
    readonly = None;
    mcp_context_required = None;
    idempotent = None;
    required_permission;
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

let with_required_permission required_permission meta =
  { meta with required_permission }
;;

let readonly_tool =
  with_execution_policy
    ~readonly:true
    ~idempotent:false
    (default_metadata ~required_permission:Masc_domain.CanReadState)

let mutating_tool =
  with_execution_policy
    ~readonly:false
    ~idempotent:false
    (default_metadata ~required_permission:Masc_domain.CanBroadcast)

let masc_workspace_tool =
  with_execution_policy
    ~readonly:false
    ~idempotent:false
    (default_metadata ~required_permission:Masc_domain.CanBroadcast)

let read_state_tool = readonly_tool
let broadcast_tool = masc_workspace_tool
let add_task_tool = with_required_permission Masc_domain.CanAddTask masc_workspace_tool
let claim_task_tool = with_required_permission Masc_domain.CanClaimTask masc_workspace_tool
let complete_task_tool = with_required_permission Masc_domain.CanCompleteTask masc_workspace_tool
let vote_tool = with_required_permission Masc_domain.CanVote masc_workspace_tool
let init_tool = with_required_permission Masc_domain.CanInit mutating_tool
let reset_tool = with_required_permission Masc_domain.CanReset mutating_tool
let admin_tool = with_required_permission Masc_domain.CanAdmin mutating_tool

let local_runtime_tool operation =
  let policy = Local_runtime_tool_policy.execution_policy operation in
  with_execution_policy
    ~readonly:policy.read_only
    ~idempotent:policy.idempotent
    (default_metadata ~required_permission:policy.required_permission)
;;

let hidden_runtime_tool reason meta =
  {
    meta with
    visibility = Hidden;
    allow_direct_call_when_hidden = true;
    reason = Some reason;
  }

let keeper_shard_permission required_permission =
  hidden_runtime_tool
    "Keeper shard runtime tool; permission is catalog-owned while execution policy is descriptor-owned."
    (default_metadata ~required_permission)
;;

let keeper_shard_read = keeper_shard_permission Masc_domain.CanReadState
let keeper_shard_write = keeper_shard_permission Masc_domain.CanBroadcast
let keeper_shard_add_task = keeper_shard_permission Masc_domain.CanAddTask
(* ================================================================ *)
(* Explicit metadata registry                                       *)
(* ================================================================ *)

let explicit_metadata : (string * metadata) list =
  [
    ( "masc_operator_judgment_write",
      hidden_active
        ~required_permission:Masc_domain.CanAdmin
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
    ("masc_transition", complete_task_tool);
    ("masc_plan_set_task", broadcast_tool);
    ("masc_broadcast", with_semantic_flags ~mcp_context_required:true broadcast_tool);
    ("channel_gate", broadcast_tool);
    (* Auth keys owned by the approval-mode HTTP routes themselves, not
       borrowed from a dispatchable tool. [with_tool_auth] resolves the
       caller's role through the catalog entry named by ~tool_name, so an
       HTTP route needs a name here to be authorizable at all; these two
       exist only for that lookup. They are hidden runtime keys with no
       schema and no dispatch path, so they never appear on the public MCP
       surface and cannot be called as tools.

       Review (#30533): these decide what a running turn is allowed to do —
       answering a held call, or turning a keeper's approval gate off until
       restart. Worker tokens carry [CanBroadcast] for normal chat writes;
       they must not be able to flip any keeper's approval stance, so both
       keys sit at [CanAdmin] like the voice transcribe route's operator
       quota. The two routes also keep separate keys: answering one held
       call (keeper_tool_approval_route) and disabling the whole gate
       (keeper_tool_approval_mode_route) are different weights of action. *)
    ( "keeper_tool_approval_route",
      hidden_runtime_tool
        "Auth key for the tool-approval HTTP route (answering a held tool \
         call); no schema, no dispatch path, route-authority only. Admin \
         tier: a worker token must not answer held calls for keepers it \
         does not own."
        admin_tool );
    ( "keeper_tool_approval_mode_route",
      hidden_runtime_tool
        "Auth key for the tool-approval-mode HTTP route (setting the \
         per-keeper approval stance); no schema, no dispatch path, \
         route-authority only. Admin tier: setting YOLO for a keeper \
         disables its approval gate until restart, which is not a \
         broadcast-level action."
        admin_tool );
    (* Run schemas register from tool_run.ml; catalog still owns early auth metadata.
       RFC-0182: 7 dead admin tools (masc_execute_dry_run, masc_admin_cleanup,
       masc_admin_reset, masc_gc_force, masc_workspace_delete, masc_force_unbind,
       masc_execute) removed — no dispatch path, no schema, no caller. *)
    ( "masc_operator_action",
      with_required_permission
        Masc_domain.CanAdmin
        (hidden_active
           ~required_permission:Masc_domain.CanAdmin
           "Internal operator-action route; hidden from the public tool surface.") );
    ( "masc_operator_board_attention_quarantine_requeue",
      with_execution_policy
        ~readonly:false
        ~idempotent:true
        (with_required_permission
           Masc_domain.CanAdmin
           (hidden_active
           ~allow_direct_call_when_hidden:false
           ~required_permission:Masc_domain.CanAdmin
           "Operator-profile-only exact recovery of one Board-attention quarantine.")) );
    ( "masc_operator_task_recovery_resolve",
      with_execution_policy
        ~readonly:false
        ~idempotent:false
        (with_required_permission
           Masc_domain.CanAdmin
           (hidden_active
           ~allow_direct_call_when_hidden:false
           ~required_permission:Masc_domain.CanAdmin
           "Operator-profile-only exact owner/version recovery of one Task.")) );
    ( "masc_set_param",
      with_required_permission
        Masc_domain.CanAdmin
        (hidden_active
           ~required_permission:Masc_domain.CanAdmin
           "Internal HTTP runtime-parameter mutation route; hidden from the public tool surface.") );
    (* Catalog-owned permissions for split/lazily registered tool modules. *)
    ("masc_start", with_semantic_flags ~mcp_context_required:true init_tool);
    ("masc_task_history", read_state_tool);
    ("masc_add_task", add_task_tool);
    ("masc_batch_add_tasks", add_task_tool);
    ("masc_task_set_goal", complete_task_tool);
    ("masc_update_priority", complete_task_tool);
    ("masc_heartbeat", broadcast_tool);
    ("masc_goal_list", read_state_tool);
    ("masc_goal_upsert", broadcast_tool);
    ("masc_goal_transition", broadcast_tool);
    ("masc_keeper_list", read_state_tool);
    ("masc_keeper_status", read_state_tool);
    ("masc_keeper_sandbox_start", broadcast_tool);
    ("masc_keeper_sandbox_stop", mutating_tool);
    ("masc_keeper_delegate", broadcast_tool);
    ("masc_keeper_delegate_status", read_state_tool);
    (* Submits an async chat operation (same submit_agent_operation path as
       masc_keeper_delegate); poll masc_keeper_delegate_status for the
       outcome. *)
    ("masc_keeper_msg", broadcast_tool);
    ("masc_keeper_delegate_cancel", broadcast_tool);
    ("masc_keeper_delegate_list", read_state_tool);
    ("masc_keeper_audit", read_state_tool);
    ("masc_keeper_waiting_inventory", read_state_tool);
    ("masc_keeper_up", broadcast_tool);
    ("masc_keeper_down", admin_tool);
    ("masc_keeper_clear", admin_tool);
    ("masc_keeper_reset", reset_tool);
    ("masc_plan_get_task", read_state_tool);
    ("masc_plan_clear_task", broadcast_tool);
    ("masc_config", read_state_tool);
    ("masc_check", read_state_tool);
    ("masc_agent_fitness", read_state_tool);
    ("masc_agent_timeline", read_state_tool);
    ("masc_get_metrics", read_state_tool);
    ("masc_operator_snapshot", read_state_tool);
    ("masc_operator_digest", read_state_tool);
    ("masc_operator_confirm", broadcast_tool);
    ("masc_runtime_verify", local_runtime_tool Local_runtime_tool_policy.Verify);
    ( "masc_runtime_ollama_probe"
    , local_runtime_tool Local_runtime_tool_policy.Ollama_probe );
    ("masc_board_hearths", read_state_tool);
    ("masc_board_search", read_state_tool);
    ("masc_board_profile", read_state_tool);
    ("masc_board_stats", read_state_tool);
    ("masc_board_sub_board_list", read_state_tool);
    ("masc_board_sub_board_get", read_state_tool);
    ("masc_ask", broadcast_tool);
    ("masc_ask_status", read_state_tool);
    ("masc_ask_withdraw", broadcast_tool);
    ("masc_board_post", broadcast_tool);
    ("masc_board_post_update", broadcast_tool);
    ("masc_board_comment", broadcast_tool);
    ("masc_board_vote", vote_tool);
    ("masc_board_comment_vote", vote_tool);
    ("masc_board_reaction", vote_tool);
    ("masc_board_sub_board_create", broadcast_tool);
    ("masc_board_sub_board_update", broadcast_tool);
    ("masc_board_sub_board_delete", broadcast_tool);
    ("masc_board_cleanup", admin_tool);
    ("masc_board_delete", admin_tool);
    ("masc_gc", admin_tool);
    (* POST /api/v1/prompts. An override replaces a prompt for every keeper the
       runtime serves, so it carries the same admin permission as the other
       fleet-wide mutations here. *)
    ("masc_prompt_override", admin_tool);
    ("masc_pause", broadcast_tool);
    ("masc_resume", broadcast_tool);
    ("masc_pause_status", read_state_tool);
    ("masc_run_get", broadcast_tool);
    ("masc_run_list", read_state_tool);
    ("masc_run_init", broadcast_tool);
    ("masc_run_plan", broadcast_tool);
    ("masc_schedule_create", broadcast_tool);
    ("masc_schedule_update", broadcast_tool);
    ("masc_schedule_list", read_state_tool);
    ("masc_schedule_get", read_state_tool);
    ("masc_schedule_cancel", broadcast_tool);
    (* Keeper-only: a spawned process belongs to the turn's switch, and the
       MCP boundary has no turn to end it, so these are callable from a keeper
       and absent from the public schema surface. *)
    (* Keeper-only: the language server belongs to the turn's pool, and the
       MCP boundary has no turn to end it. *)
    ( "keeper_code_query",
      hidden_runtime_tool
        "Keeper code-query runtime tool; it asks the turn's language server, so it is \
         callable from a keeper and hidden from the public MCP schema surface."
        read_state_tool );
    (* Keeper-only WebMCP consumption (RFC-webmcp-keeper-consumption): the
       bridge targets an operator-run Chrome, which the MCP boundary has no
       business reaching. *)
    ( "keeper_webmcp_list",
      hidden_runtime_tool
        "Keeper WebMCP discovery tool; lists tools a browser page registered, callable \
         from a keeper and hidden from the public MCP schema surface."
        read_state_tool );
    ( "keeper_webmcp_call",
      keeper_shard_write );
    ( "keeper_spawn",
      hidden_runtime_tool
        "Keeper spawn runtime tool; the process it starts belongs to the turn, so it is \
         callable from a keeper and hidden from the public MCP schema surface."
        broadcast_tool );
    ( "keeper_spawn_read",
      hidden_runtime_tool
        "Keeper spawn-read runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "keeper_spawn_wait",
      hidden_runtime_tool
        "Keeper spawn-wait runtime tool; it blocks for a caller-stated bound, so it is not \
         admitted as read-only, and it is hidden from the public MCP schema surface."
        broadcast_tool );
    ( "keeper_spawn_stop",
      hidden_runtime_tool
        "Keeper spawn-stop runtime tool; callable but hidden from the public MCP schema surface."
        broadcast_tool );
    ("masc_fusion", broadcast_tool);
    ("masc_fusion_status", read_state_tool);
    ("masc_library_list", read_state_tool);
    ("masc_library_read", read_state_tool);
    ("masc_library_add", broadcast_tool);
    ("masc_library_search", read_state_tool);
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
    ( "keeper_task_cancel",
      (* Same permission as the release beside it, for the same reason: both
         reach [masc_transition], and a different one here would let the same
         request succeed on one surface and fail on the other. *)
      hidden_runtime_tool
        "Keeper task-cancel runtime tool; callable but hidden from the public MCP schema surface."
        complete_task_tool );
    ( "keeper_task_release",
      (* Same permission as [masc_transition], whose release action this
         covers: picking a different one would let the same release succeed
         on one surface and fail on the other. *)
      hidden_runtime_tool
        "Keeper task-release runtime tool; callable but hidden from the public MCP schema surface."
        complete_task_tool );
    ( "keeper_tools_list",
      hidden_runtime_tool
        "Keeper tool-list runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    ( "keeper_capability_search",
      hidden_runtime_tool
        "Keeper capability-search runtime tool; callable but hidden from the public MCP schema surface."
        read_state_tool );
    (* Keeper shard schemas are registered directly by [Unified_tool_registry],
       not through [Tool_spec].  Their callable names still need an explicit
       permission authority here; descriptor policy remains the SSOT for
       execution axes such as readonly/idempotent. *)
    ("keeper_time_now", keeper_shard_read);
    ("keeper_lane_status", keeper_shard_read);
    ("keeper_context_status", keeper_shard_read);
    ("keeper_artifact_read", keeper_shard_read);
    ("keeper_memory_search", keeper_shard_read);
    ("keeper_memory_retract", keeper_shard_write);
    ("keeper_memory_write", keeper_shard_write);
    ("keeper_library_search", keeper_shard_read);
    ("keeper_library_read", keeper_shard_read);
    ("keeper_surface_read", keeper_shard_read);
    ("keeper_surface_post", keeper_shard_write);
    ("keeper_person_note_set", keeper_shard_write);
    ("keeper_ide_annotate", keeper_shard_write);
    ("keeper_voice_speak", keeper_shard_write);
    ("keeper_voice_listen", keeper_shard_write);
    ("keeper_voice_agent", keeper_shard_read);
    ("keeper_voice_sessions", keeper_shard_read);
    ("keeper_voice_session_start", keeper_shard_write);
    ("keeper_voice_session_end", keeper_shard_write);
    ("keeper_tasks_audit", keeper_shard_read);
    ("keeper_broadcast", keeper_shard_write);
    ("keeper_handoff", keeper_shard_write);
    ("keeper_task_create", keeper_shard_add_task);
    ("tool_edit_file", keeper_shard_write);
    ("tool_write_file", keeper_shard_write);
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

(* Every name this catalog has an opinion about, static entries and anything
   registered at load time alike. The contract tests need it because the
   schema lists they used to walk are not the same set: the catalog decides
   admission for tools whose schemas live outside Config's front door, and a
   corpus built from those lists never visits them. *)
let known_names () =
  Hashtbl.fold (fun name _ acc -> name :: acc) metadata_table []
  |> List.sort_uniq String.compare
;;

let register_metadata_for_testing name (meta : metadata) =
  Hashtbl.replace metadata_table name meta

let register_runtime_metadata name (meta : metadata) =
  match Hashtbl.find_opt metadata_table name with
  | None ->
    Error
      (Printf.sprintf
         "tool %s has no catalog-owned required permission"
         name)
  | Some authority ->
    Hashtbl.replace
      metadata_table
      name
      { meta with required_permission = authority.required_permission };
    Ok ()

let registered_metadata name =
  Hashtbl.find_opt metadata_table name

module For_testing = struct
  let register_metadata = register_metadata_for_testing
end

(* ================================================================ *)
(* Public MCP surface — delegates to Tool_catalog_surfaces (SSOT)   *)
(* ================================================================ *)

let public_mcp_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  List.iter (fun name -> Hashtbl.replace tbl name ())
    Tool_catalog_surfaces.public_mcp_surface_tools;
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
    (* An unclassified tool is never granted a worker-capable permission. The
       catalog has no evidence for a narrower policy, so the typed fallback
       is operator-only and registration/authentication still require an
       explicit catalog entry. *)
    let fail_closed = default_metadata ~required_permission:Masc_domain.CanAdmin in
    if is_public_mcp name
    then fail_closed
    else
      (* External MCP discovery remains an explicit public-surface contract.
         It must not be reused as Keeper authorization or model visibility. *)
      { fail_closed with
        visibility = Hidden
      ; allow_direct_call_when_hidden = true
      ; reason = Some "Not on the external MCP discovery surface."
      }

let implementation_status name =
  let meta = metadata name in
  meta.implementation_status

let is_placeholder name =
  match implementation_status name with
  | Placeholder -> true
  | Real | Adapter | Simulation -> false

let is_visible ?(include_hidden = false) name =
  let meta = metadata name in
  match meta.visibility with
  | Hidden when include_hidden -> true
  (* MASC_PLACEHOLDER_TOOLS_ENABLED (compat): RFC-0371 B7 removed the
     env read because no deployment set it, but operators relied on
     `MASC_PLACEHOLDER_TOOLS_ENABLED=false` to hide placeholder tools.
     Restored with [get_bool ~default:true] — setting it to false/0/no
     hides placeholders; unset or true keeps the pre-B7 behavior. *)
  | Hidden when is_placeholder name ->
    Env_config_core.get_bool ~default:true "MASC_PLACEHOLDER_TOOLS_ENABLED"
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
      ( "requiredPermission"
      , `String (Masc_domain.permission_to_string meta.required_permission) );
    ]
  in
  let with_reason =
    match meta.reason with
    | Some reason -> ("reason", `String reason) :: base
    | None -> base
  in
  let with_mcp_context_required =
    match meta.mcp_context_required with
    | Some value -> ("mcpContextRequired", `Bool value) :: with_reason
    | None -> with_reason
  in
  with_mcp_context_required

let allow_direct_call name =
  let meta = metadata name in
  match meta.visibility with
  | Default -> true
  | Hidden -> meta.allow_direct_call_when_hidden
