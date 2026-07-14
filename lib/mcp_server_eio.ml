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
    - Mcp_session_store: durable MCP session helpers
*)

(** {1 Re-exported Types} *)

type server_state = Mcp_server.server_state
type jsonrpc_request = Mcp_transport_protocol.jsonrpc_request

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

type eio_net = [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t

(** {1 Eio Context Wrappers} *)

let set_net net = Eio_context.set_net net
let set_clock clock = Eio_context.set_clock clock
let get_clock_opt () = Eio_context.get_clock_opt ()

(** {1 State Construction} *)
let get_clock () = Eio_context.get_clock ()

let create_state ?test_mode ~base_path () =
  let state = Mcp_server.create_state ~base_path in
  (match test_mode with
   | Some true -> Auth.disable_auth base_path
   | _ -> ());
  state

let create_state_eio ~sw ~proc_mgr ~fs ~clock ~mono_clock ~net ~base_path =
  Mcp_server.create_state_eio
    ~sw
    ~proc_mgr
    ~fs
    ~clock
    ~mono_clock
    ~net:(net :> Eio_context.eio_net)
    ~base_path
;;

(** {1 Re-exported Mcp_server Functions} *)

let is_jsonrpc_response = Mcp_transport_protocol.is_jsonrpc_response
let get_id = Mcp_transport_protocol.get_id
let is_valid_request_id = Mcp_transport_protocol.is_valid_request_id
let validate_initialize_params = Mcp_transport_protocol.validate_initialize_params
let has_field = Mcp_transport_protocol.has_field
let get_field = Mcp_transport_protocol.get_field

type mcp_session_record = Mcp_session_store.mcp_session_record =
  { id : string
  ; agent_name : string option
  ; created_at : float
  ; last_seen : float
  }

let mcp_session_to_json = Mcp_session_store.mcp_session_to_json
let mcp_session_of_json = Mcp_session_store.mcp_session_of_json

(* Tag registry initialization.
   Most modules register via Tool_spec.register at module load time.
   Inline schemas and domain adapters that need composition-root wiring
   remain here. *)
let () =
  let open Tool_dispatch in
  register_module_tag ~schemas:Tool_schemas_inline.schemas ~tag:Mod_inline;
  Board_tool.register ();
  (* P0-1 unified tool registry ratchet: fill any gaps left by module-load
     [Tool_spec] registrations and ensure every LLM-visible schema has a tag.
     Safe to call multiple times; existing registrations are preserved. *)
  Unified_tool_registry.register_all ();
  Unified_tool_registry.enforce_visible_tag_coverage ();
  mark_tag_registry_initialized ();
  (* Inject masc_* schemas into keeper bridge for surface/policy filtering.
     Uses Config.raw_all_tool_schemas, including domain-adapter schemas not
     present in Tools.all_schemas_extended. *)
  Keeper_tool_dispatch_runtime.inject_masc_schemas Config.raw_all_tool_schemas;
  (* Wire tag-based dispatch for keeper masc_* tools.
     See #4579: keeper_tool_dispatch_runtime uses handler registry (Tool_Board only),
     this callback adds tag-registry dispatch for ~190 more tools. *)
  Keeper_tool_shared_runtime.tag_dispatch_fn := Keeper_tag_dispatch.dispatch;
  Log.Mcp.info "Tag registry initialized: %d tools registered" (tag_registry_count ());
  (* C-4: Register input schema validation pre-hook.
     Validates tool arguments against their declared input_schema
     before dispatch — catches missing required fields and type mismatches. *)
  Tool_input_validation.register_pre_hook ()
;;

(** {1 execute_tool_eio -- included from Mcp_server_eio_execute} *)

include Mcp_server_eio_execute

(** {1 Resource Subscription Re-exports} *)

let clear_resource_subscriptions_for_session =
  Mcp_server_eio_protocol.clear_resource_subscriptions_for_session
;;

(** {1 Public API} *)

let handle_request
      ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
      ~sw
      ?(profile = Full)
      ?mcp_session_id
      ?otel_mcp_protocol_version
      ?otel_transport_context
      ?auth_token
      ?(internal_keeper_runtime = false)
      state
      request_str
  =
  Mcp_server_eio_protocol.handle_request
    ~handle_call_tool_eio:
      (fun
        ~sw
        ~clock
        ~profile
        ?mcp_session_id
        ?auth_token
        ~internal_keeper_runtime
        state
        id
        params ->
      Mcp_server_eio_call_tool.handle_call_tool_eio
        ~execute_tool_eio
        ~maybe_emit_resource_notifications:
          Mcp_server_eio_protocol.maybe_emit_resource_notifications
        ~broadcast_tools_list_changed:Mcp_server_eio_protocol.broadcast_tools_list_changed
        ~sw
        ~clock
        ~profile
        ?mcp_session_id
        ?auth_token
        ~internal_keeper_runtime
        state
        id
        params)
    ~handle_read_resource_eio:Mcp_server_eio_resource.handle_read_resource_eio
    ~clock
    ~sw
    ~profile:(profile : tool_profile :> Mcp_server_eio_types.tool_profile)
    ?mcp_session_id
    ?otel_mcp_protocol_version
    ?otel_transport_context
    ?auth_token
    ~internal_keeper_runtime
    state
    request_str
;;

let run_stdio ~sw ~env state =
  let handle_request ~clock ~sw ~mcp_session_id state request_str =
    handle_request ~clock ~sw ~mcp_session_id state request_str
  in
  Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env state
;;
