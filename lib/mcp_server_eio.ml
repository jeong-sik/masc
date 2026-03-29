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
type jsonrpc_request = Mcp_server.jsonrpc_request
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

let is_jsonrpc_response = Mcp_server.is_jsonrpc_response
let get_id = Mcp_server.get_id
let is_valid_request_id = Mcp_server.is_valid_request_id
let validate_initialize_params = Mcp_server.validate_initialize_params
let has_field = Mcp_server.has_field
let get_field = Mcp_server.get_field

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
  register_module_tag ~schemas:Tool_plan.schemas ~tag:Mod_plan;
  register_module_tag ~schemas:Tool_operator.schemas ~tag:Mod_operator;
  register_module_tag ~schemas:Tool_command_plane.schemas ~tag:Mod_command_plane;
  register_module_tag ~schemas:Tool_local_runtime.schemas ~tag:Mod_local_runtime;
  (* Backward-compatible aliases: old masc_llama_* names route to local_runtime *)
  register_name_tag ~tool_name:"masc_llama_models" ~tag:Mod_local_runtime;
  register_name_tag ~tool_name:"masc_llama_runtime_status" ~tag:Mod_local_runtime;
  register_name_tag ~tool_name:"masc_llama_runtime_bench" ~tag:Mod_local_runtime;
  register_name_tag ~tool_name:"masc_llama_runtime_verify" ~tag:Mod_local_runtime;
  register_module_tag ~schemas:Tool_team_session.schemas ~tag:Mod_team_session;
  register_module_tag ~schemas:Tool_voice.schemas ~tag:Mod_voice;
  register_module_tag ~schemas:Tool_portal.schemas ~tag:Mod_portal;
  register_module_tag ~schemas:Tool_worktree.schemas ~tag:Mod_worktree;
  register_module_tag ~schemas:Tool_auth.schemas ~tag:Mod_auth;
  register_module_tag ~schemas:Tool_agent.schemas ~tag:Mod_agent;
  register_module_tag ~schemas:Tool_room.schemas ~tag:Mod_room;
  register_module_tag ~schemas:Tool_agent_timeline.schemas ~tag:Mod_agent_timeline;
  register_module_tag ~schemas:Tool_keeper.schemas ~tag:Mod_keeper;
  register_module_tag ~schemas:Tool_mdal.schemas ~tag:Mod_mdal;
  register_module_tag ~schemas:Tool_improve_loop.schemas ~tag:Mod_improve_loop;
  register_module_tag ~schemas:Tool_autoresearch.schemas ~tag:Mod_autoresearch;
  register_module_tag ~schemas:Tool_research.schemas ~tag:Mod_research;
  (* God Schema decomposition: register modules that now own their schemas *)
  register_module_tag ~schemas:Tool_task.schemas ~tag:Mod_task;
  register_module_tag ~schemas:Tool_control.schemas ~tag:Mod_control;
  register_module_tag ~schemas:Tool_suspend.schemas ~tag:Mod_suspend;
  register_module_tag ~schemas:Tool_council_oas.schemas ~tag:Mod_council;
  register_module_tag ~schemas:Tool_relay.schemas ~tag:Mod_relay;
  register_module_tag ~schemas:Tool_handover.schemas ~tag:Mod_handover;
  register_module_tag ~schemas:Tool_hat.schemas ~tag:Mod_hat;
  register_module_tag ~schemas:Tool_cache.schemas ~tag:Mod_cache;
  register_module_tag ~schemas:Tool_goals.schemas ~tag:Mod_goals;
  register_module_tag ~schemas:Tool_compact.schemas ~tag:Mod_compact;
  register_module_tag ~schemas:Tool_schemas_inline.schemas ~tag:Mod_inline;
  (* Monolithic schema decomposition: modules that now export their own schemas *)
  register_module_tag ~schemas:Tool_code.schemas ~tag:Mod_code;
  register_module_tag ~schemas:Tool_code_write.schemas ~tag:Mod_code_write;
  register_module_tag ~schemas:Tool_library.schemas ~tag:Mod_library;
  register_module_tag ~schemas:Tool_a2a.schemas ~tag:Mod_a2a;
  register_module_tag ~schemas:Tool_heartbeat.schemas ~tag:Mod_heartbeat;
  register_module_tag ~schemas:Tool_misc.schemas ~tag:Mod_misc;
  (* Fix 2: Register modules that lack schema exports.
     Tool_tag_init uses register_name_tag for remaining modules
     that still rely on name-based registration. Called AFTER schema-based
     registrations so it fills gaps without overwriting correct mappings. *)
  Tool_tag_init.register_all ();
  mark_tag_registry_initialized ();
  (* Inject masc_* schemas into keeper bridge for profile-based filtering.
     Must happen after all schemas are assembled. *)
  Keeper_exec_tools.inject_masc_schemas Tools.all_schemas_extended;
  Log.Mcp.info "Tag registry initialized: %d tools registered" (tag_registry_count ());
  (* C-4: Register input schema validation pre-hook.
     Validates tool arguments against their declared input_schema
     before dispatch — catches missing required fields and type mismatches. *)
  Tool_input_validation.register_pre_hook ()

(** {1 execute_tool_eio -- included from Mcp_server_eio_execute} *)

include Mcp_server_eio_execute

let () = Chain_native_eio.set_tool_executor execute_tool_eio

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
