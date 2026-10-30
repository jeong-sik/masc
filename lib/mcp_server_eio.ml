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
*)

(** {1 Re-exported Types} *)

type server_state = Mcp_server.server_state

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Seat

type eio_net = [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t

(** {1 Eio Context Wrappers} *)

let set_net net = Eio_context.set_net net
let set_clock clock = Eio_context.set_clock clock
let get_clock_opt () = Eio_context.get_clock_opt ()

(** {1 State Construction} *)
let get_clock () = Eio_context.get_clock ()

let tool_schema_component_bytes ~name ~description ~input_schema =
  String.length name
  + String.length description
  + String.length (Yojson.Safe.to_string input_schema)
;;

module For_testing = struct
  let create_state ~base_path () =
    let state = Mcp_server.For_testing.create_state ~base_path in
    Auth.disable_auth base_path;
    state
  ;;
end

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

(* Tag registry initialization. *)
let () =
  let open Tool_dispatch in
  Board_tool.register ();
  (* P0-1 unified tool registry ratchet: fill any gaps left by module-load
     [Tool_spec] registrations and ensure every LLM-visible schema has a tag.
     Safe to call multiple times; existing registrations are preserved. *)
  Unified_tool_registry.register_all ();
  Unified_tool_registry.enforce_visible_tag_coverage ();
  mark_tag_registry_initialized ();
  (* Report exact visible schema-component bytes. Provider tokenization is not
     inferred before dispatch; authoritative token usage arrives in responses. *)
  (let schemas = Config.visible_tool_schemas () in
   let count = List.length schemas in
   let component_bytes =
     List.fold_left
       (fun acc (s : Masc_domain.tool_schema) ->
          acc
          + tool_schema_component_bytes
              ~name:s.name
              ~description:s.description
              ~input_schema:s.input_schema)
       0
       schemas
   in
   Otel_metric_store.set_tool_schema_stats ~count ~component_bytes);
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
        call ->
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
        call)
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

let run_stdio ?auth_token ~sw ~env state =
  let handle_request ~clock ~sw ~mcp_session_id state request_str =
    let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
    let authorization =
      try
        let config = Auth.load_auth_config base_path in
        if not config.Masc_domain.enabled then Ok ()
        else
          match auth_token with
          | None when not config.require_token -> Ok ()
          | None -> Error (Mcp_error_code.Auth_error, "Unauthorized: bearer token required")
          | Some token ->
            (match Auth_credential_token.find_credential_by_token base_path ~token with
             | Ok (credential : Masc_domain.agent_credential)
               when Masc_domain.has_permission credential.role Masc_domain.CanReadState -> Ok ()
             | Ok _ ->
               Error (Mcp_error_code.Auth_error, "Forbidden: this stdio endpoint requires CanReadState")
             | Error _ -> Error (Mcp_error_code.Auth_error, "Unauthorized: invalid or expired bearer token"))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> Error (Mcp_error_code.Internal_error, "Authentication configuration unavailable")
    in
    let rejection =
      match authorization with
      | Ok () -> None
      | Error (code, message) ->
        match Yojson.Safe.from_string request_str with
        | json when Mcp_transport_protocol.is_jsonrpc_v2 json
                    && Mcp_transport_protocol.has_unique_jsonrpc_fields json ->
          (match Mcp_transport_protocol.jsonrpc_request_of_yojson json with
           | Ok request when Mcp_transport_protocol.is_notification request -> Some `Null
           | Ok request ->
             let id = Mcp_transport_protocol.get_id request in
             if Mcp_transport_protocol.is_valid_request_id id then
               Some (Mcp_transport_protocol.make_error ~id
                 (Mcp_error_code.to_wire_code code) message)
             else None
           | Error _ -> None)
        | _ | exception Yojson.Json_error _ -> None
    in
    match rejection with
    | Some response -> response
    | None -> handle_request ~clock ~sw ?mcp_session_id ?auth_token state request_str
  in
  Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env state
;;
