(** MCP Protocol Server Implementation - Eio Native

    Direct-style async MCP server using OCaml 5.x Effect Handlers.

    Sub-modules (extracted for maintainability):
    - Mcp_server_eio_types: Shared types (tool_profile)
    - Mcp_server_eio_helpers: Logging, unregister_sync, wait_for_message_eio
    - Mcp_server_eio_resource: Resource reading handler
    - Mcp_server_eio_execute: Core execute_tool_eio function
    - Mcp_server_eio_call_tool: Tool call handler (retry, timeout, result envelope)
    - Mcp_server_eio_tool_profile: Profile/schema/annotation/pagination helpers
    - Mcp_server_eio_dispatch: Context construction + V2/legacy dispatch chain
    - Mcp_server_eio_protocol: JSON-RPC handlers, subscriptions, transport
    - Mcp_server_eio_governance: Governance and MCP session helpers
*)

[@@@warning "-32"]

(** {1 Re-exported Types} *)

type server_state = Mcp_server.server_state
type jsonrpc_request = Mcp_server.jsonrpc_request
type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Role_filtered of Mode.mode

type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

(** {1 Logging} *)

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn

(** {1 Eio Context Wrappers} *)

let set_net net = Eio_context.set_net net
let set_clock clock = Eio_context.set_clock clock
let get_clock_opt () = Eio_context.get_clock_opt ()
let get_clock () = Eio_context.get_clock ()
let get_net_opt () : eio_net option = Eio_context.get_net_opt ()
let get_net () : eio_net = Eio_context.get_net ()

(** {1 State Construction} *)

let create_state ?test_mode:_ ~base_path () =
  Mcp_server.create_state ~base_path

let create_state_eio ~sw ~env ~proc_mgr ~fs ~clock ~net ~base_path =
  let state = Mcp_server.create_state_eio ~sw ~env ~proc_mgr ~fs ~clock
    ~net:(net :> Eio_context.eio_net) ~base_path in
  (try Team_session_engine_eio.recover_running_sessions ~sw ~clock
         ~config:state.Mcp_server.room_config
   with exn -> log_mcp_exn ~label:"team_session recovery skipped" exn);
  state

(** {1 Re-exported Mcp_server Functions} *)

let is_jsonrpc_v2 = Mcp_server.is_jsonrpc_v2
let is_jsonrpc_response = Mcp_server.is_jsonrpc_response
let is_notification = Mcp_server.is_notification
let get_id = Mcp_server.get_id
let is_valid_request_id = Mcp_server.is_valid_request_id
let jsonrpc_request_of_yojson = Mcp_server.jsonrpc_request_of_yojson
let protocol_version_from_params = Mcp_server.protocol_version_from_params
let normalize_protocol_version = Mcp_server.normalize_protocol_version
let validate_protocol_version = Mcp_server.validate_protocol_version
let validate_initialize_params = Mcp_server.validate_initialize_params
let make_response = Mcp_server.make_response
let make_error = Mcp_server.make_error
let has_field = Mcp_server.has_field
let get_field = Mcp_server.get_field

let public_tool_help_schemas () = Config.visible_tool_schemas ()

(** {1 Session Adapters} *)

let unregister_sync = Mcp_server_eio_helpers.unregister_sync
let wait_for_message_eio = Mcp_server_eio_helpers.wait_for_message_eio

(** {1 Governance Re-exports} *)

type governance_config = Mcp_server_eio_governance.governance_config = {
  level: string;
  audit_enabled: bool;
  anomaly_detection: bool;
}
let governance_defaults = Mcp_server_eio_governance.governance_defaults
let load_governance = Mcp_server_eio_governance.load_governance
let save_governance = Mcp_server_eio_governance.save_governance

type mcp_session_record = Mcp_server_eio_governance.mcp_session_record = {
  id: string;
  agent_name: string option;
  created_at: float;
  last_seen: float;
}
let mcp_session_to_json = Mcp_server_eio_governance.mcp_session_to_json
let mcp_session_of_json = Mcp_server_eio_governance.mcp_session_of_json
let load_mcp_sessions = Mcp_server_eio_governance.load_mcp_sessions
let save_mcp_sessions = Mcp_server_eio_governance.save_mcp_sessions

(** {1 Drift Guard Re-exports} *)

let tokenize = Drift_guard.tokenize
let jaccard_similarity = Drift_guard.jaccard_similarity
let cosine_similarity = Drift_guard.cosine_similarity

(** {1 Tool Lists} *)

let read_only_tools =
  ["masc_status"; "masc_tasks"; "masc_who"; "masc_agents";
   "masc_messages"; "masc_task_history"; "masc_votes"; "masc_vote_status";
   "masc_worktree_list"; "masc_pending_interrupts";
   "masc_cost_report"; "masc_portal_status";
   "masc_verify_handoff"; "masc_tool_help";
   "masc_goal_list"; "masc_team_session_status"; "masc_team_session_report";
   "masc_team_session_list"; "masc_team_session_compare";
   "masc_team_session_events"; "masc_team_session_prove";
   "masc_operator_snapshot"; "masc_operator_digest"]

let requires_join_tools = [
  "masc_add_task"; "masc_claim"; "masc_claim_next"; "masc_transition";
  "masc_broadcast"; "masc_listen"; "masc_heartbeat";
  "masc_plan_set_task"; "masc_plan_clear_task";
  "masc_worktree_create"; "masc_worktree_remove"; "masc_worktree_list";
  "masc_portal_open"; "masc_portal_send"; "masc_portal_close";
  "masc_vote_cast"; "masc_vote_revoke";
  "masc_register_capabilities"; "masc_suspend"; "masc_leave";
  "masc_operator_action"; "masc_operator_confirm";
]

let () = Tool_dispatch.init_read_only_set read_only_tools
let () = Tool_dispatch.init_requires_join_set requires_join_tools

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
    ~clock ~sw ~execute_tool_eio ~log_mcp_exn
    ~profile:(profile : tool_profile :> Mcp_server_eio_types.tool_profile)
    ?mcp_session_id ?auth_token state request_str

let run_stdio ~sw ~env state =
  Mcp_server_eio_protocol.run_stdio ~sw ~env ~execute_tool_eio ~log_mcp_exn state
