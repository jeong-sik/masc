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

type eio_net = [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t

(** {1 Eio Context Wrappers} *)

let set_net net = Eio_context.set_net net
let set_clock clock = Eio_context.set_clock clock
let get_clock_opt () = Eio_context.get_clock_opt ()

(** {1 State Construction} *)
let get_clock () = Eio_context.get_clock ()

let create_state ?test_mode:_ ~base_path () = Mcp_server.create_state ~base_path

let create_state_eio ~sw ~proc_mgr ~fs ~clock ~mono_clock ~net ~base_path =
  let state =
    Mcp_server.create_state_eio
      ~sw
      ~proc_mgr
      ~fs
      ~clock
      ~mono_clock
      ~net:(net :> Eio_context.eio_net)
      ~base_path
  in
  Session.start_loop state.session_registry ~sw;
  Tool_registry.start_actor_if_needed ~sw;
  Oas_worker_cascade.start_actor_if_needed ~sw;
  state
;;

(** {1 Re-exported Mcp_server Functions} *)

let is_jsonrpc_response = Mcp_transport_protocol.is_jsonrpc_response
let get_id = Mcp_transport_protocol.get_id
let is_valid_request_id = Mcp_transport_protocol.is_valid_request_id
let validate_initialize_params = Mcp_transport_protocol.validate_initialize_params
let has_field = Mcp_transport_protocol.has_field
let get_field = Mcp_transport_protocol.get_field

(** {1 Governance Re-exports} *)

type governance_config = Mcp_server_eio_governance.governance_config =
  { level : string
  ; audit_enabled : bool
  ; anomaly_detection : bool
  }

let governance_defaults = Mcp_server_eio_governance.governance_defaults

type mcp_session_record = Mcp_server_eio_governance.mcp_session_record =
  { id : string
  ; agent_name : string option
  ; created_at : float
  ; last_seen : float
  }

let mcp_session_to_json = Mcp_server_eio_governance.mcp_session_to_json
let mcp_session_of_json = Mcp_server_eio_governance.mcp_session_of_json

(** {1 Tool Lists — inline sub-library tools plus keeper read-only fallback}

    Most tools register read_only/requires_join via Tool_spec.register
    in their own modules. These lists cover only tools from
    Tool_schemas_inline (lib/tool_schemas/ sub-library) which cannot
    depend on Tool_spec, plus keeper read-only tools declared via
    Tool_shard schemas. *)

let read_only_tools_inline =
  List.map Tool_name.Masc.to_string Tool_name.Masc.[ Status; Who; Messages ]
;;

let requires_join_tools_inline =
  List.map Tool_name.Masc.to_string Tool_name.Masc.[ Broadcast; Leave ]
;;

let mcp_context_required_tools_inline =
  Tool_schemas_inline.schemas
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)
;;

let () =
  (* [Keeper_exec_tools.keeper_read_only_tools] is the keeper SSOT.
     Server bootstrap mirrors that list into Tool_dispatch so protocol
     annotations and non-keeper callers see the same read-only metadata. *)
  Tool_dispatch.init_read_only_set
    (read_only_tools_inline @ Keeper_exec_tools.keeper_read_only_tools)
;;

let () = Tool_dispatch.init_requires_join_set requires_join_tools_inline
let () = Tool_dispatch.init_mcp_context_required_set mcp_context_required_tools_inline

(* Tools whose arguments contain executable commands subject to
   destructive pattern scanning (eval_gate step 6).
   Covers: keeper tools (eval_gate), OAS hooks (keeper_hooks_oas),
   and worker tools (worker_oas). *)
let () =
  Tool_dispatch.init_destructive_set
    [ "keeper_bash"
    ; "keeper_fs_edit"
    ; "shell_exec"
    ; "masc_code_shell"
    ; "masc_code_git"
    ; "masc_code_delete"
    ]
;;

(* Tag registry initialization.
   Most modules register via Tool_spec.register at module load time.
   Only Tool_schemas_inline (sub-library) and Board remain here. *)
let () =
  let open Tool_dispatch in
  register_module_tag ~schemas:Tool_schemas_inline.schemas ~tag:Mod_inline;
  Tool_board.register ();
  mark_tag_registry_initialized ();
  (* Inject masc_* schemas into keeper bridge for surface/policy filtering.
     Uses Config.raw_all_tool_schemas which includes Board schemas
     not present in Tools.all_schemas_extended. *)
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  (* Report tool schema budget to Prometheus (#7483 Step 1). *)
  (let schemas = Config.visible_tool_schemas () in
   let count = List.length schemas in
   let chars =
     List.fold_left
       (fun acc (s : Types.tool_schema) ->
          acc
          + String.length s.name
          + String.length s.description
          + String.length (Yojson.Safe.to_string s.input_schema))
       0
       schemas
   in
   Prometheus.set_tool_schema_stats ~count ~approx_tokens:(chars / 4));
  (* Wire keeper-internal tool call recording to break Config dependency cycle.
     keeper_exec_tools cannot reference Tool_registry directly. *)
  (Keeper_exec_tools.on_keeper_tool_call
   := fun ~tool_name ~success ~duration_ms ->
        Tool_registry.record_call
          ~source:Keeper_internal
          ~tool_name
          ~success
          ~duration_ms
          ());
  (* Wire tag-based dispatch for keeper masc_* tools.
     Breaks the same Config dependency cycle as on_keeper_tool_call.
     See #4579: keeper_exec_tools uses handler registry (Tool_Board only),
     this callback adds tag-registry dispatch for ~190 more tools. *)
  Keeper_exec_shared.tag_dispatch_fn := Keeper_tag_dispatch.dispatch;
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
    ?auth_token
    ~internal_keeper_runtime
    state
    request_str
;;

(** Re-export transport mode from protocol for backward compatibility *)
type transport_mode = Mcp_server_eio_protocol.transport_mode =
  | Framed
  | LineDelimited

let detect_mode = Mcp_server_eio_protocol.detect_mode

let run_stdio ~sw ~env state =
  let handle_request ~clock ~sw ~mcp_session_id state request_str =
    handle_request ~clock ~sw ~mcp_session_id state request_str
  in
  Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env state
;;
