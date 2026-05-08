(** Mcp_server_eio_protocol — JSON-RPC protocol handlers and SSE transport

    Extracted from mcp_server_eio.ml.
    Handles initialize, list (tools/resources/prompts), subscribe, request dispatch,
    resource subscriptions, and stdio transport.
*)

module TP = Mcp_server_eio_tool_profile

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

let make_response = Mcp_transport_protocol.make_response
let make_error = Mcp_transport_protocol.make_error
let is_jsonrpc_v2 = Mcp_transport_protocol.is_jsonrpc_v2
let is_jsonrpc_response = Mcp_transport_protocol.is_jsonrpc_response
let get_id = Mcp_transport_protocol.get_id
let is_valid_request_id = Mcp_transport_protocol.is_valid_request_id
let jsonrpc_request_of_yojson = Mcp_transport_protocol.jsonrpc_request_of_yojson

let unavailable_tool_message name =
  if Tool_catalog.is_on_surface Tool_catalog.Keeper_internal name
  then (
    let replacement_hint =
      match (Tool_catalog.metadata name).Tool_catalog.replacement with
      | Some replacement -> Printf.sprintf " Try `%s` instead." replacement
      | None -> ""
    in
    Printf.sprintf
      "Tool '%s' is keeper-internal and unavailable on this MCP endpoint.%s"
      name
      replacement_hint)
  else Printf.sprintf "Tool '%s' is not available on this MCP endpoint." name
;;

(** {1 Resource Subscriptions} *)

let resource_subscription_mutex = Eio.Mutex.create ()
let with_resource_subscription_lock f = Eio_guard.with_mutex resource_subscription_mutex f

let resource_subscriptions : (string, (string, unit) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 64
;;

let resource_is_dynamic uri =
  let lower = String.lowercase_ascii uri in
  not
    (String.contains lower '{'
     || String.starts_with ~prefix:"masc://schema" lower
     || String.starts_with ~prefix:"masc://institution" lower
     || String.starts_with ~prefix:"masc://tool-help" lower)
;;

let subscribe_resource_for_session ~session_id ~uri =
  with_resource_subscription_lock (fun () ->
    let uris =
      match Hashtbl.find_opt resource_subscriptions session_id with
      | Some uris -> uris
      | None ->
        let uris = Hashtbl.create 8 in
        Hashtbl.replace resource_subscriptions session_id uris;
        uris
    in
    Hashtbl.replace uris uri ())
;;

let unsubscribe_resource_for_session ~session_id ~uri =
  with_resource_subscription_lock (fun () ->
    match Hashtbl.find_opt resource_subscriptions session_id with
    | Some uris ->
      Hashtbl.remove uris uri;
      if Hashtbl.length uris = 0 then Hashtbl.remove resource_subscriptions session_id
    | None -> ())
;;

let clear_resource_subscriptions_for_session session_id =
  with_resource_subscription_lock (fun () ->
    Hashtbl.remove resource_subscriptions session_id)
;;

let jsonrpc_notification = Mcp_transport_protocol.jsonrpc_notification

let send_resource_updated_notification ~session_id ~uri =
  Sse.send_to
    session_id
    (jsonrpc_notification
       "notifications/resources/updated"
       ~params:(`Assoc [ "uri", `String uri ]))
;;

let broadcast_tools_list_changed () =
  Sse.broadcast (jsonrpc_notification "notifications/tools/list_changed")
;;

let dedup_strings items = items |> List.sort_uniq String.compare
let core_status_resource_ids = [ "status"; "status.json"; "events"; "events.json" ]

let task_resource_ids =
  dedup_strings (core_status_resource_ids @ [ "tasks"; "tasks.json" ])
;;

let agent_resource_ids =
  dedup_strings (core_status_resource_ids @ [ "who"; "who.json"; "agents"; "agents.json" ])
;;

let message_resource_ids =
  dedup_strings (core_status_resource_ids @ [ "messages"; "messages.json" ])
;;

let worktree_resource_ids =
  dedup_strings (core_status_resource_ids @ [ "worktrees"; "worktrees.json" ])
;;

let resource_id_of_uri uri =
  let resource_id, _uri = Mcp_server.parse_masc_resource_uri uri in
  resource_id
;;

let affected_resource_ids_for_tool = function
  | "masc_add_task"
  | "masc_claim_next"
  | "masc_transition"
  | "masc_update_priority"
  | "masc_plan_set_task"
  | "masc_plan_clear_task" -> task_resource_ids
  | "masc_join"
  | "masc_leave"
  | "masc_register_capabilities"
  | "masc_heartbeat"
  | "masc_suspend" -> agent_resource_ids
  | "masc_broadcast" | "masc_portal_open" | "masc_portal_send" | "masc_portal_close" ->
    message_resource_ids
  | "masc_worktree_create" | "masc_worktree_remove" -> worktree_resource_ids
  | _ -> core_status_resource_ids
;;

let maybe_emit_resource_notifications ~success ~tool_name =
  if success && not (Tool_dispatch.is_read_only tool_name)
  then (
    let affected_ids = affected_resource_ids_for_tool tool_name in
    with_resource_subscription_lock (fun () ->
      Hashtbl.iter
        (fun session_id uris ->
           Hashtbl.iter
             (fun uri () ->
                if
                  resource_is_dynamic uri
                  && List.mem (resource_id_of_uri uri) affected_ids
                then send_resource_updated_notification ~session_id ~uri)
             uris)
        resource_subscriptions))
;;

(** {1 Protocol Handlers} *)

let handle_initialize_eio ?(profile = Full) id params =
  match Mcp_transport_protocol.validate_initialize_params params with
  | Error msg -> make_error ~id (-32602) msg
  | Ok () ->
    let protocol_version =
      params |> Mcp_transport_protocol.protocol_version_from_params
    in
    (match Mcp_transport_protocol.validate_protocol_version protocol_version with
     | Error msg -> make_error ~id (-32602) msg
     | Ok protocol_version ->
       make_response
         ~id
         (`Assoc
             [ "protocolVersion", `String protocol_version
             ; "serverInfo", Mcp_server.server_info
             ; "capabilities", Mcp_server.capabilities
             ; ( "instructions"
               , `String
                   (match profile with
                    | Full -> TP.default_instructions
                    | Managed_agent -> TP.managed_agent_instructions
                    | Operator_remote -> TP.operator_remote_instructions) )
             ; ( "_meta"
               , `Assoc
                   [ "serverStartedAt", `String (Masc_domain.now_iso ())
                   ; "serverVersion", `String Version.version
                   ; ( "profile"
                     , `String
                         (match profile with
                          | Full -> "full"
                          | Managed_agent -> "managed_agent"
                          | Operator_remote -> "operator_remote") )
                   ] )
             ]))
;;

let public_tool_help_schemas () = Config.visible_tool_schemas ()

let handle_list_tools_eio
      ?(profile = Full)
      ?names
      ?(include_hidden = false)
      ?(include_deprecated = false)
      ?(include_usage = false)
      ?(include_keeper_internal = false)
      ?cursor
      ?agent_id
      state
      id
  =
  let usage_summary =
    if include_usage
    then
      Some
        (Telemetry_eio.summarize_tool_usage
           ?fs:state.Mcp_server.fs
           state.Mcp_server.room_config)
    else None
  in
  let tools =
    TP.tool_schemas_for_profile
      ~include_hidden
      ~include_deprecated
      ~include_keeper_internal
      state
      profile
    |> (match names with
      | None -> Fun.id
      | Some wanted ->
        List.filter (fun (schema : Masc_domain.tool_schema) ->
          List.mem schema.name wanted))
    |> List.sort (fun (a : Masc_domain.tool_schema) (b : Masc_domain.tool_schema) ->
      let rank (schema : Masc_domain.tool_schema) =
        if
          include_keeper_internal
          && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal schema.name
        then 0
        else 1
      in
      match Int.compare (rank a) (rank b) with
      | 0 -> String.compare a.name b.name
      | order -> order)
  in
  (match agent_id with
   | Some aid ->
     let tool_names = List.map (fun (s : Masc_domain.tool_schema) -> s.name) tools in
     let profile_str =
       match profile with
       | Full -> "full"
       | Managed_agent -> "managed_agent"
       | Operator_remote -> "operator_remote"
     in
     ignore
       (Tool_assignment_telemetry.emit_assigned
          ~agent_id:aid
          ~profile:profile_str
          ~tool_list:tool_names
          ~reason:"mcp tools/list response"
          ())
   | None -> ());
  let total_count = List.length tools in
  match TP.page_items_with_cursor ~kind:"tools" tools cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
    let result_fields =
      [ "tools", `List (List.map (TP.tool_json_for_profile ?usage_summary profile) page) ]
      @ TP.maybe_assoc_field
          "nextCursor"
          (Option.map (fun value -> `String value) next_cursor)
      @ [ ( "_meta"
          , `Assoc
              [ "totalCount", `Int total_count; "pageSize", `Int (TP.list_page_size ()) ]
          )
        ]
    in
    let result_fields =
      result_fields
      @
      match usage_summary with
      | Some summary ->
        [ "usageTelemetryAvailable", `Bool summary.telemetry_available
        ; "usageTelemetryPath", `String summary.telemetry_path
        ; "usageTotalCalls", `Int summary.total_calls
        ]
      | None -> []
    in
    make_response ~id (`Assoc result_fields)
;;

let handle_list_resources_eio id cursor =
  let tool_help_resources =
    public_tool_help_schemas ()
    |> List.sort (fun (a : Masc_domain.tool_schema) (b : Masc_domain.tool_schema) ->
      String.compare a.name b.name)
    |> List.map (fun (schema : Masc_domain.tool_schema) ->
      let entry = Tool_help_registry.entry_of_schema schema in
      Mcp_server.make_resource
        ~uri:("masc://tool-help/" ^ schema.name)
        ~name:(schema.name ^ " Help")
        ~description:entry.short_description
        ~mime_type:"text/markdown"
        ())
  in
  let resources =
    Mcp_server.resources @ tool_help_resources
    |> List.sort (fun (a : Mcp_server.mcp_resource) b -> String.compare a.uri b.uri)
  in
  match TP.page_items_with_cursor ~kind:"resources" resources cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
    let resources_json = List.map Mcp_server.resource_to_json page in
    let result_fields =
      [ "resources", `List resources_json ]
      @ TP.maybe_assoc_field
          "nextCursor"
          (Option.map (fun value -> `String value) next_cursor)
    in
    make_response ~id (`Assoc result_fields)
;;

let handle_list_resource_templates_eio id cursor =
  let templates =
    Mcp_server.resource_templates
    |> List.sort (fun (a : Mcp_server.mcp_resource_template) b ->
      String.compare a.uri_template b.uri_template)
  in
  match TP.page_items_with_cursor ~kind:"resourceTemplates" templates cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
    let templates_json = List.map Mcp_server.resource_template_to_json page in
    let result_fields =
      [ "resourceTemplates", `List templates_json ]
      @ TP.maybe_assoc_field
          "nextCursor"
          (Option.map (fun value -> `String value) next_cursor)
    in
    make_response ~id (`Assoc result_fields)
;;

let handle_list_prompts_eio id cursor =
  let prompts =
    Mcp_prompt_surface.prompt_defs
    |> List.sort
         (fun (a : Mcp_prompt_surface.prompt_def) (b : Mcp_prompt_surface.prompt_def) ->
            String.compare a.name b.name)
  in
  match TP.page_items_with_cursor ~kind:"prompts" prompts cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
    let prompts_json = List.map Mcp_prompt_surface.prompt_json page in
    let result_fields =
      [ "prompts", `List prompts_json ]
      @ TP.maybe_assoc_field
          "nextCursor"
          (Option.map (fun value -> `String value) next_cursor)
    in
    make_response ~id (`Assoc result_fields)
;;

let handle_get_prompt_eio state id params =
  match params with
  | None -> make_error ~id (-32602) "Missing params"
  | Some (`Assoc _ as payload) ->
    let open Yojson.Safe.Util in
    (match payload |> member "name" with
     | `String name ->
       let arguments =
         match payload |> member "arguments" with
         | `Assoc _ as args -> args
         | `Null -> `Assoc []
         | _ -> `Assoc []
       in
       (match
          Mcp_prompt_surface.get_json
            ~config:state.Mcp_server.room_config
            ~name
            ~arguments
            Config.raw_all_tool_schemas
        with
        | Ok json -> make_response ~id json
        | Error msg -> make_error ~id (-32602) msg)
     | _ -> make_error ~id (-32602) "Invalid params: name must be a string")
  | Some _ -> make_error ~id (-32602) "Invalid params: expected object"
;;

let handle_resources_subscribe_eio id ?mcp_session_id params =
  let open Yojson.Safe.Util in
  match mcp_session_id, params with
  | None, _ -> make_error ~id (-32600) "resources/subscribe requires an MCP session"
  | Some session_id, Some (`Assoc _ as payload) ->
    (match payload |> member "uri" with
     | `String uri ->
       subscribe_resource_for_session ~session_id ~uri;
       make_response ~id (`Assoc [])
     | _ -> make_error ~id (-32602) "Invalid params: uri must be a string")
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"
;;

let handle_resources_unsubscribe_eio id ?mcp_session_id params =
  let open Yojson.Safe.Util in
  match mcp_session_id, params with
  | None, _ -> make_error ~id (-32600) "resources/unsubscribe requires an MCP session"
  | Some session_id, Some (`Assoc _ as payload) ->
    (match payload |> member "uri" with
     | `String uri ->
       unsubscribe_resource_for_session ~session_id ~uri;
       make_response ~id (`Assoc [])
     | _ -> make_error ~id (-32602) "Invalid params: uri must be a string")
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"
;;

let optional_string_member key fields =
  match List.assoc_opt key fields with
  | Some (`String value) ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | Some `Null | None -> None
  | Some _ -> None
;;

let string_list_member key fields =
  match List.assoc_opt key fields with
  | Some (`List values) ->
    values
    |> List.filter_map (function
      | `String value ->
        let trimmed = String.trim value in
        if trimmed = "" then None else Some trimmed
      | _ -> None)
  | _ -> []
;;

let dashboard_response_or_error id = function
  | Ok result -> make_response ~id result
  | Error msg -> make_error ~id (-32600) msg
;;

let handle_dashboard_hello_eio state id ?mcp_session_id params =
  match mcp_session_id, params with
  | None, _ -> make_error ~id (-32600) "dashboard/hello requires a WebSocket session"
  | Some session_id, Some (`Assoc fields) ->
    let token = optional_string_member "token" fields in
    Server_mcp_transport_ws.dashboard_hello
      ~base_path:state.Mcp_server.room_config.base_path
      ~session_id
      ?token
      ()
    |> dashboard_response_or_error id
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"
;;

let handle_dashboard_subscribe_eio state id ?mcp_session_id params =
  match mcp_session_id, params with
  | None, _ -> make_error ~id (-32600) "dashboard/subscribe requires a WebSocket session"
  | Some session_id, Some (`Assoc fields) ->
    let route = optional_string_member "route" fields in
    let slices = string_list_member "slices" fields in
    let slices = if slices = [] then [ "shell"; "namespace"; "transport" ] else slices in
    ignore state;
    Server_mcp_transport_ws.dashboard_subscribe ~session_id ?route ~slices ()
    |> dashboard_response_or_error id
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"
;;

let handle_dashboard_unsubscribe_eio id ?mcp_session_id params =
  match mcp_session_id, params with
  | None, _ ->
    make_error ~id (-32600) "dashboard/unsubscribe requires a WebSocket session"
  | Some session_id, Some (`Assoc fields) ->
    let slices = string_list_member "slices" fields in
    let slices_opt = if slices = [] then None else Some slices in
    Server_mcp_transport_ws.dashboard_unsubscribe ~session_id ?slices:slices_opt ()
    |> dashboard_response_or_error id
  | Some session_id, None ->
    Server_mcp_transport_ws.dashboard_unsubscribe ~session_id ()
    |> dashboard_response_or_error id
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"
;;

let handle_dashboard_ack_eio id ?mcp_session_id params =
  match mcp_session_id, params with
  | None, _ -> make_error ~id (-32600) "dashboard/ack requires a WebSocket session"
  | Some session_id, Some (`Assoc fields) ->
    let seq =
      match List.assoc_opt "seq" fields with
      | Some (`Int n) -> n
      | _ -> 0
    in
    (* Client reports WebSocket.bufferedAmount alongside every ack so the
         server can observe when a dashboard is falling behind.  The key is
         camelCase to match the TypeScript client's wire representation; the
         value is dropped when negative or absent so a malformed client
         cannot poison the gauge. *)
    let buffered_amount =
      match List.assoc_opt "bufferedAmount" fields with
      | Some (`Int n) when n >= 0 -> Some n
      | Some (`Float f) when f >= 0.0 && Float.is_finite f -> Some (int_of_float f)
      | _ -> None
    in
    Server_mcp_transport_ws.dashboard_ack ~session_id ~seq ?buffered_amount ()
    |> dashboard_response_or_error id
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"
;;

let handle_dashboard_ack_notification ?mcp_session_id params =
  ignore (handle_dashboard_ack_eio `Null ?mcp_session_id params);
  `Null
;;

let contains_casefold = Mcp_server_eio_call_tool.contains_casefold

let tool_call_outcome (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some _ -> "error"
     | None ->
       (match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) ->
          (match List.assoc_opt "isError" result_fields with
           | Some (`Bool true) -> "error"
           | Some (`Bool false) -> "ok"
           | _ -> "unknown")
        | _ -> "unknown"))
  | _ -> "unknown"
;;

let jsonrpc_id_label = function
  | `String s -> s
  | `Int i -> string_of_int i
  | `Intlit s -> s
  | `Float f -> Printf.sprintf "%0.0f" f
  | _ -> "?"
;;

let tool_profile_label = function
  | Full -> "full"
  | Managed_agent -> "managed_agent"
  | Operator_remote -> "operator_remote"
;;

let mcp_tool_call_log_details ?outcome ~phase ~profile ~tool_name ~id ?mcp_session_id () =
  `Assoc
    ([ "event_family", `String "tool_call"
     ; "tool_name", `String tool_name
     ; "phase", `String phase
     ; "request_id", `String (jsonrpc_id_label id)
     ; ( "session_id"
       , match mcp_session_id with
         | Some session_id -> `String session_id
         | None -> `Null )
     ; "profile", `String (tool_profile_label profile)
     ]
     @
     match outcome with
     | Some value -> [ "outcome", `String value ]
     | None -> [])
;;

(** Handle incoming JSON-RPC request - Pure Eio Native *)
let handle_request
      ~handle_call_tool_eio
      ~handle_read_resource_eio
      ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
      ~sw
      ?(profile = Full)
      ?mcp_session_id
      ?auth_token
      ?(internal_keeper_runtime = false)
      state
      request_str
  =
  try
    let json =
      try Ok (Yojson.Safe.from_string request_str) with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Printexc.to_string exn)
    in
    match json with
    | Error msg -> make_error ~id:`Null ~data:(`String msg) (-32700) "Parse error"
    | Ok json ->
      if
        match json with
        | `List _ -> true
        | _ -> false
      then
        make_error
          ~id:`Null
          (-32600)
          "JSON-RPC batch requests are not supported on this MCP endpoint"
      else if is_jsonrpc_response json
      then `Null
      else if not (is_jsonrpc_v2 json)
      then make_error ~id:`Null (-32600) "Invalid Request: jsonrpc must be 2.0"
      else (
        match jsonrpc_request_of_yojson json with
        | Error msg -> make_error ~id:`Null ~data:(`String msg) (-32600) "Invalid Request"
        | Ok req ->
          let id = get_id req in
          if not (is_valid_request_id id)
          then
            make_error
              ~id:`Null
              (-32600)
              "Invalid Request: id must be string, number, or null"
          else if Mcp_transport_protocol.is_notification req
          then (
            match req.method_ with
            | "dashboard/ack" ->
              handle_dashboard_ack_notification ?mcp_session_id req.params
            | _ -> `Null)
          else (
            try
              match req.method_ with
              | "initialize" -> handle_initialize_eio ~profile id req.params
              | "initialized" | "notifications/initialized" -> make_response ~id `Null
              | "resources/list" ->
                (match TP.parse_cursor_only_params req.params with
                 | Error msg -> make_error ~id (-32602) msg
                 | Ok { cursor } -> handle_list_resources_eio id cursor)
              | "resources/read" -> handle_read_resource_eio state id req.params
              | "resources/templates/list" ->
                (match TP.parse_cursor_only_params req.params with
                 | Error msg -> make_error ~id (-32602) msg
                 | Ok { cursor } -> handle_list_resource_templates_eio id cursor)
              | "resources/subscribe" ->
                handle_resources_subscribe_eio id ?mcp_session_id req.params
              | "resources/unsubscribe" ->
                handle_resources_unsubscribe_eio id ?mcp_session_id req.params
              | "dashboard/hello" ->
                handle_dashboard_hello_eio state id ?mcp_session_id req.params
              | "dashboard/subscribe" ->
                handle_dashboard_subscribe_eio state id ?mcp_session_id req.params
              | "dashboard/unsubscribe" ->
                handle_dashboard_unsubscribe_eio id ?mcp_session_id req.params
              | "dashboard/ack" -> handle_dashboard_ack_eio id ?mcp_session_id req.params
              | "prompts/list" ->
                (match TP.parse_cursor_only_params req.params with
                 | Error msg -> make_error ~id (-32602) msg
                 | Ok { cursor } -> handle_list_prompts_eio id cursor)
              | "prompts/get" -> handle_get_prompt_eio state id req.params
              | "tools/list" ->
                (match TP.requested_tool_list_params req.params with
                 | Error msg -> make_error ~id (-32602) msg
                 | Ok { names; include_hidden; include_deprecated; include_usage; cursor }
                   ->
                   let list_profile =
                     match profile with
                     | Managed_agent | Operator_remote -> profile
                     | Full -> Full
                   in
                   handle_list_tools_eio
                     ~profile:list_profile
                     ?names
                     ~include_hidden
                     ~include_deprecated
                     ~include_usage
                     ~include_keeper_internal:internal_keeper_runtime
                     ?cursor
                     ?agent_id:auth_token
                     state
                     id)
              | "tools/call" ->
                (match req.params with
                 | Some params ->
                   (try
                      let name =
                        Yojson.Safe.Util.(params |> member "name" |> to_string)
                      in
                      (* Issue #8699: exhaustive match on tool_profile.
                               Catch-all `_ -> Full` would silently elevate any
                               future restricted profile to full tool access
                               (fail-OPEN). Listing every constructor turns a
                               new profile into a compile error so the access
                               decision is reviewed at the boundary. *)
                      let call_profile =
                        match profile with
                        | Operator_remote | Managed_agent -> profile
                        | Full -> Full
                      in
                      if
                        not
                          (TP.tool_allowed_in_profile
                             ~internal_keeper_runtime
                             state
                             call_profile
                             name)
                      then make_error ~id (-32601) (unavailable_tool_message name)
                      else (
                        Log.Mcp.emit
                          Log.Info
                          ~details:
                            (mcp_tool_call_log_details
                               ~phase:"started"
                               ~profile:call_profile
                               ~tool_name:name
                               ~id
                               ?mcp_session_id
                               ())
                          (Printf.sprintf
                             "tools/call: %s (id=%s, session=%s)"
                             name
                             (jsonrpc_id_label id)
                             (match mcp_session_id with
                              | Some s -> s
                              | None -> "none"));
                        let result =
                          handle_call_tool_eio
                            ~sw
                            ~clock
                            ~profile
                            ?mcp_session_id
                            ?auth_token
                            ~internal_keeper_runtime
                            state
                            id
                            params
                        in
                        let outcome = tool_call_outcome result in
                        Log.Mcp.emit
                          Log.Info
                          ~details:
                            (mcp_tool_call_log_details
                               ~phase:"completed"
                               ~profile:call_profile
                               ~tool_name:name
                               ~id
                               ?mcp_session_id
                               ~outcome
                               ())
                          (Printf.sprintf
                             "tools/call completed: %s (outcome=%s)"
                             name
                             outcome);
                        result)
                    with
                    | Yojson.Safe.Util.Type_error (_, _) ->
                      make_error ~id (-32602) "Invalid params: name must be a string")
                 | None -> make_error ~id (-32602) "Missing params")
              | method_ when Mcp_sdk_adapter_masc.handles_method method_ ->
                Mcp_sdk_adapter_masc.dispatch_request
                  ~handle_call_tool_eio
                  ~state
                  ~profile
                  ~sw
                  ~clock
                  ?mcp_session_id
                  ?auth_token
                  json
                |> Option.value ~default:`Null
              | method_ -> make_error ~id (-32601) ("Method not found: " ^ method_)
            with
            | Invalid_argument msg when contains_casefold msg "masc not initialized" ->
              make_error
                ~id
                (-32603)
                (Masc_domain.masc_error_to_string
                   (Masc_domain.System Masc_domain.System_error.NotInitialized))
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              let err = Printexc.to_string exn in
              Log.Mcp.error "Request handling failed: method=%s: %s" method_ err;
              make_error ~id (-32603) (Printf.sprintf "Internal error: %s" err)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    make_error
      ~id:`Null
      ~data:(`String (Printexc.to_string exn))
      (-32603)
      "Internal error"
;;

(** {1 Transport} *)

type transport_mode =
  | Framed (* Content-Length prefixed - MCP stdio mode *)
  | LineDelimited (* One JSON per line - simple mode *)

let detect_mode first_line =
  let lower = String.lowercase_ascii first_line in
  if String.starts_with lower ~prefix:"content-length" then Framed else LineDelimited
;;

(** Read newline-delimited message from Eio flow *)
let read_line_message buf =
  try Some (Eio.Buf_read.line buf) with
  | End_of_file -> None
;;

(** Write Content-Length prefixed message to Eio flow *)
let write_framed_message flow json =
  let body = Yojson.Safe.to_string json in
  let header = Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length body) in
  Eio.Flow.copy_string header flow;
  Eio.Flow.copy_string body flow
;;

(** Write newline-delimited message to Eio flow *)
let write_line_message flow json =
  let body = Yojson.Safe.to_string json in
  Eio.Flow.copy_string body flow;
  Eio.Flow.copy_string "\n" flow
;;

(** Run MCP server in stdio mode with Eio *)
let run_stdio ~handle_request ~sw ~env state =
  let stdin = Eio.Stdenv.stdin env in
  let stdout = Eio.Stdenv.stdout env in
  let clock = Eio.Stdenv.clock env in
  Log.Mcp.info "MASC MCP Server (Eio stdio mode)";
  Log.Mcp.info "Default room: %s" Mcp_server.(state.room_config.Coord.base_path);
  let buf = Eio.Buf_read.of_flow stdin ~max_size:(16 * 1024 * 1024) in
  let read_framed_message_after_first_line first_line =
    let rec read_headers acc =
      let line = Eio.Buf_read.line buf in
      if String.length line = 0 || line = "\r"
      then List.rev acc
      else read_headers (line :: acc)
    in
    let headers = read_headers [ first_line ] in
    let content_length =
      headers
      |> List.find_map (fun header ->
        let header = String.trim header in
        if
          String.length header > 16
          && String.lowercase_ascii (String.sub header 0 15) = "content-length:"
        then (
          let len_str = String.trim (String.sub header 15 (String.length header - 15)) in
          int_of_string_opt len_str)
        else None)
      |> Option.value ~default:0
    in
    if content_length > 0 then Some (Eio.Buf_read.take content_length buf) else None
  in
  let respond ~mode response =
    match response with
    | `Null -> ()
    | json ->
      (match mode with
       | Framed -> write_framed_message stdout json
       | LineDelimited -> write_line_message stdout json)
  in
  let rec loop mode_opt =
    match read_line_message buf with
    | None ->
      Log.Mcp.info "EOF received, shutting down";
      ()
    | Some first_line ->
      let first_line = String.trim first_line in
      if first_line = ""
      then loop mode_opt
      else (
        let mode =
          match mode_opt with
          | Some mode -> mode
          | None ->
            let detected = detect_mode first_line in
            let mode_name =
              match detected with
              | Framed -> "framed (Content-Length)"
              | LineDelimited -> "line-delimited JSON"
            in
            Log.Mcp.debug "Transport mode: %s" mode_name;
            detected
        in
        let request_opt =
          match mode with
          | Framed -> read_framed_message_after_first_line first_line
          | LineDelimited -> Some first_line
        in
        match request_opt with
        | None ->
          Log.Mcp.info "EOF received, shutting down";
          ()
        | Some "" -> loop (Some mode)
        | Some request_str ->
          let response =
            handle_request ~clock ~sw ~mcp_session_id:"stdio" state request_str
          in
          respond ~mode response;
          loop (Some mode))
  in
  try loop None with
  | End_of_file -> Log.Mcp.info "Connection closed"
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Mcp.error "Server error: %s" (Printexc.to_string exn)
;;
