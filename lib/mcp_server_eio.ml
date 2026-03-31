(** MCP Protocol Server Implementation - Eio Native

    Direct-style async MCP server using OCaml 5.x Effect Handlers.

    Sub-modules (extracted for maintainability):
    - Mcp_server_eio_types: Shared types (tool_profile)
    - Mcp_server_eio_helpers: Logging, wait_for_message_eio
    - Mcp_server_eio_resource: Resource reading handler
    - Mcp_server_eio_execute: Core execute_tool_eio function
    - Mcp_server_eio_call_tool: Tool call handler (retry, timeout, result envelope)
    - Mcp_server_eio_tool_profile: Profile/schema/annotation/pagination helpers
    - Mcp_server_eio_protocol: JSON-RPC handlers, subscriptions, transport
    - Mcp_server_eio_governance: Governance and MCP session helpers
*)


(** {1 Re-exported Types} *)

type server_state = Mcp_server.server_state
type jsonrpc_request = Mcp_transport_protocol.jsonrpc_request
type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

(** {1 Eio Context Wrappers} *)

let set_net net = Eio_context.set_net net
let set_clock clock = Eio_context.set_clock clock
let get_clock_opt () = Eio_context.get_clock_opt ()
let get_clock () = Eio_context.get_clock ()
(** {1 State Construction} *)

let create_state ?test_mode:_ ~base_path () =
  Mcp_server.create_state ~base_path

let create_state_eio ~sw ~env ~proc_mgr ~fs ~clock ~mono_clock ~net ~base_path =
  Mcp_server.create_state_eio ~sw ~env ~proc_mgr ~fs ~clock ~mono_clock
    ~net:(net :> Eio_context.eio_net) ~base_path

(** {1 Re-exported Mcp_server Functions} *)

let is_jsonrpc_response = Mcp_transport_protocol.is_jsonrpc_response
let get_id = Mcp_transport_protocol.get_id
let is_valid_request_id = Mcp_transport_protocol.is_valid_request_id
let validate_initialize_params = Mcp_transport_protocol.validate_initialize_params
let has_field = Mcp_transport_protocol.has_field
let get_field = Mcp_transport_protocol.get_field

(** {1 Governance Re-exports} *)

type governance_config = Mcp_server_eio_governance.governance_config = {
  level: string;
  audit_enabled: bool;
  anomaly_detection: bool;
}
let governance_defaults = Mcp_server_eio_governance.governance_defaults

type mcp_session_record = Mcp_server_eio_governance.mcp_session_record = {
  id: string;
  agent_name: string option;
  created_at: float;
  last_seen: float;
}
let mcp_session_to_json = Mcp_server_eio_governance.mcp_session_to_json
let mcp_session_of_json = Mcp_server_eio_governance.mcp_session_of_json

(** {1 Tool Lists} *)

let read_only_tools =
  ["masc_status"; "masc_tasks"; "masc_who"; "masc_agents";
   "masc_messages"; "masc_task_history"; "masc_votes"; "masc_vote_status";
   "masc_transport_status"; "masc_websocket_discovery";
   "masc_worktree_list"; "masc_pending_interrupts";
   "masc_portal_status";
   "masc_verify_handoff"; "masc_tool_help";
   "masc_team_session_status"; "masc_team_session_report";
   "masc_team_session_list"; "masc_team_session_compare";
   "masc_team_session_events"; "masc_team_session_prove";
   "masc_operator_snapshot"; "masc_operator_digest";
   "masc_surface_audit"; "masc_collaboration_evidence";
   "masc_improve_loop_status"]

let requires_join_tools = [
  "masc_add_task"; "masc_claim_next"; "masc_transition";
  "masc_broadcast"; "masc_listen"; "masc_heartbeat";
  "masc_plan_set_task"; "masc_plan_clear_task";
  "masc_worktree_create"; "masc_worktree_remove";
  "masc_portal_open"; "masc_portal_send"; "masc_portal_close";
  "masc_vote_cast"; "masc_vote_revoke";
  "masc_register_capabilities"; "masc_suspend"; "masc_leave";
  "masc_operator_action"; "masc_operator_confirm";
  "masc_improve_loop_start"; "masc_improve_loop_pause";
  "masc_improve_loop_resume"; "masc_improve_loop_tick";
]

let () = Tool_dispatch.init_read_only_set read_only_tools
let () = Tool_dispatch.init_requires_join_set requires_join_tools

(* Fix 1: Populate tag registry once at module load time.
   Maps tool names to module tags for O(1) dispatch. *)
let () =
  let open Tool_dispatch in
  (* Tool_plan: migrated to Tool_spec.register *)
  (* Tool_operator: migrated to Tool_spec.register *)
  (* Tool_command_plane: migrated to Tool_spec.register *)
  (* Tool_local_runtime: migrated to Tool_spec.register *)
  (* Tool_team_session: migrated to Tool_spec.register *)
  (* Tool_voice: migrated to Tool_spec.register *)
  (* Tool_portal: migrated to Tool_spec.register *)
  (* Tool_worktree: migrated to Tool_spec.register *)
  (* Tool_auth: migrated to Tool_spec.register *)
  (* Tool_audit: migrated to Tool_spec.register *)
  (* Tool_cost: migrated to Tool_spec.register (tool_cost.ml) *)
  (* Tool_encryption: migrated to Tool_spec.register *)
  (* Tool_schemas_fire_task: migrated to Tool_spec.register *)
  (* Tool_agent: migrated to Tool_spec.register *)
  (* Tool_room: migrated to Tool_spec.register *)
  (* Tool_agent_timeline: migrated to Tool_spec.register *)
  (* Tool_keeper: migrated to Tool_spec.register *)
  (* Tool_mdal: migrated to Tool_spec.register *)
  (* Tool_repair_loop: migrated to Tool_spec.register *)
  (* Tool_improve_loop: migrated to Tool_spec.register *)
  (* Tool_autoresearch: migrated to Tool_spec.register *)
  (* Tool_research: migrated to Tool_spec.register *)
  (* God Schema decomposition: register modules that now own their schemas *)
  (* Tool_task: migrated to Tool_spec.register *)
  (* Tool_control: migrated to Tool_spec.register *)
  (* Tool_suspend: migrated to Tool_spec.register *)
  (* Tool_council_oas: migrated to Tool_spec.register *)
  (* Tool_relay: migrated to Tool_spec.register *)
  (* Tool_handover: migrated to Tool_spec.register *)
  (* Tool_hat: migrated to Tool_spec.register *)
  (* Tool_cache: migrated to Tool_spec.register (tool_cache.ml) *)
  (* Tool_model_catalog: migrated to Tool_spec.register (tool_model_catalog.ml) *)
  (* Tool_rate_limit: migrated to Tool_spec.register *)
  (* Tool_run: migrated to Tool_spec.register (tool_run.ml) *)
  (* Tool_tempo: migrated to Tool_spec.register *)
  (* Tool_goals: migrated to Tool_spec.register *)
  (* Tool_compact: migrated to Tool_spec.register (tool_compact.ml) *)
  register_module_tag ~schemas:Tool_schemas_inline.schemas ~tag:Mod_inline; (* sub-library: cannot access Tool_spec *)
  (* Monolithic schema decomposition: modules that now export their own schemas *)
  (* Tool_code: migrated to Tool_spec.register *)
  (* Tool_code_write: migrated to Tool_spec.register *)
  (* Tool_library: migrated to Tool_spec.register *)
  (* Tool_a2a: migrated to Tool_spec.register *)
  (* Tool_heartbeat: migrated to Tool_spec.register *)
  (* Tool_misc: migrated to Tool_spec.register *)
  (* Fix 2: Register modules that lack schema exports.
     Tool_tag_init uses register_name_tag for remaining modules
     that still rely on name-based registration. Called AFTER schema-based
     registrations so it fills gaps without overwriting correct mappings. *)
  Tool_tag_init.register_all ();
  Tool_board.register ();
  mark_tag_registry_initialized ();
  (* Inject masc_* schemas into keeper bridge for tier-based filtering.
     Uses Config.raw_all_tool_schemas which includes Board/MDAL schemas
     not present in Tools.all_schemas_extended. *)
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  (* Wire keeper-internal tool call recording to break Config dependency cycle.
     keeper_exec_tools cannot reference Tool_registry directly. *)
  Keeper_exec_tools.on_keeper_tool_call :=
    (fun ~tool_name ~success ~duration_ms ->
       Tool_registry.record_call ~source:Keeper_internal
         ~tool_name ~success ~duration_ms ());
  Log.Mcp.info "Tag registry initialized: %d tools registered" (tag_registry_count ());
  (* C-4: Register input schema validation pre-hook.
     Validates tool arguments against their declared input_schema
     before dispatch — catches missing required fields and type mismatches. *)
  Tool_input_validation.register_pre_hook ()

(** {1 execute_tool_eio -- included from Mcp_server_eio_execute} *)

include Mcp_server_eio_execute

(** {1 Resource Subscription Re-exports} *)

let clear_resource_subscriptions_for_session =
  Mcp_server_eio_protocol.clear_resource_subscriptions_for_session

(** {1 Public API} *)

let handle_request
    ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
    ~sw
    ?(profile = Full)
    ?mcp_session_id
    ?auth_token
    state
    request_str =
  Mcp_server_eio_protocol.handle_request
    ~handle_call_tool_eio:(fun ~sw ~clock ~profile ?mcp_session_id ?auth_token state id params ->
       Mcp_server_eio_call_tool.handle_call_tool_eio
         ~execute_tool_eio
         ~maybe_emit_resource_notifications:Mcp_server_eio_protocol.maybe_emit_resource_notifications
         ~broadcast_tools_list_changed:Mcp_server_eio_protocol.broadcast_tools_list_changed
         ~sw ~clock ~profile ?mcp_session_id ?auth_token state id params)
    ~handle_read_resource_eio:Mcp_server_eio_resource.handle_read_resource_eio
    ~clock ~sw
    ~profile:(profile : tool_profile :> Mcp_server_eio_types.tool_profile)
    ?mcp_session_id ?auth_token state request_str

(** Re-export transport mode from protocol for backward compatibility *)
type transport_mode = Mcp_server_eio_protocol.transport_mode = Framed | LineDelimited
let detect_mode = Mcp_server_eio_protocol.detect_mode

let run_stdio ~sw ~env state =
  let handle_request ~clock ~sw ~mcp_session_id state request_str =
    handle_request ~clock ~sw ~mcp_session_id state request_str
  in
  Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env state
