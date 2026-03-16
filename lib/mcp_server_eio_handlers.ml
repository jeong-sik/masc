(** Mcp_server_eio_handlers — JSON-RPC protocol handlers, request dispatch, stdio transport

    Extracted from mcp_server_eio.ml.
    Handles initialize, list (tools/resources/prompts), subscribe, request dispatch,
    and stdio transport. Receives execute_tool_eio via dependency injection.
*)

module TP = Mcp_server_eio_tool_profile
module TC = Mcp_server_eio_tool_call

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Role_filtered of Mode.mode

let make_response = Mcp_server.make_response
let make_error = Mcp_server.make_error
let is_jsonrpc_v2 = Mcp_server.is_jsonrpc_v2
let is_jsonrpc_response = Mcp_server.is_jsonrpc_response
let get_id = Mcp_server.get_id
let is_valid_request_id = Mcp_server.is_valid_request_id
let jsonrpc_request_of_yojson = Mcp_server.jsonrpc_request_of_yojson

(** {1 Protocol Handlers} *)

let handle_initialize_eio ?(profile = Full) id params =
  match Mcp_server.validate_initialize_params params with
  | Error msg -> make_error ~id (-32602) msg
  | Ok () ->
      let protocol_version =
        params |> Mcp_server.protocol_version_from_params
      in
      (match Mcp_server.validate_protocol_version protocol_version with
       | Error msg -> make_error ~id (-32602) msg
       | Ok protocol_version ->
           make_response ~id (`Assoc [
             ("protocolVersion", `String protocol_version);
             ("serverInfo", Mcp_server.server_info);
             ("capabilities", Mcp_server.capabilities);
             ( "instructions",
               `String
                 (match profile with
                 | Full | Role_filtered _ -> TP.default_instructions
                 | Managed_agent -> TP.managed_agent_instructions
                 | Operator_remote -> TP.operator_remote_instructions) );
           ]))

let public_tool_help_schemas () =
  Config.visible_tool_schemas ()

let handle_list_tools_eio ?(profile = Full) ?names ?(include_hidden = false)
    ?(include_deprecated = false) ?(include_usage = false) ?mode ?tier ?cursor
    state id =
  let usage_summary =
    if include_usage then
      Some (Telemetry_eio.summarize_tool_usage ?fs:state.Mcp_server.fs state.Mcp_server.room_config)
    else
      None
  in
  let tier_filter =
    match tier with
    | None -> None
    | Some s -> Tool_catalog.tier_of_string (String.lowercase_ascii s)
  in
  let tools =
    TP.tool_schemas_for_profile ~include_hidden ~include_deprecated
      ?mode_override:mode state profile
    |> (match names with
       | None -> Fun.id
       | Some wanted ->
           List.filter (fun (schema : Types.tool_schema) ->
             List.mem schema.name wanted))
    |> (match tier_filter with
       | None -> Fun.id
       | Some t ->
           List.filter (fun (schema : Types.tool_schema) ->
             Tool_catalog.is_in_tier t schema.name))
    |> List.sort (fun (a : Types.tool_schema) (b : Types.tool_schema) ->
           String.compare a.name b.name)
  in
  match TP.page_items_with_cursor ~kind:"tools" tools cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let result_fields =
        [
          ( "tools",
            `List
              (List.map (TP.tool_json_for_profile ?usage_summary profile) page) );
        ]
        @ TP.maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      let result_fields =
        result_fields
        @
        match usage_summary with
        | Some summary ->
            [
              ("usageTelemetryAvailable", `Bool summary.telemetry_available);
              ("usageTelemetryPath", `String summary.telemetry_path);
              ("usageTotalCalls", `Int summary.total_calls);
            ]
        | None -> []
      in
      make_response ~id (`Assoc result_fields)

let handle_list_resources_eio id cursor =
  let tool_help_resources =
    public_tool_help_schemas ()
    |> List.sort (fun (a : Types.tool_schema) (b : Types.tool_schema) ->
           String.compare a.name b.name)
    |> List.map (fun (schema : Types.tool_schema) ->
           let entry = Tool_help_registry.entry_of_schema schema in
           Mcp_server.make_resource ~uri:("masc://tool-help/" ^ schema.name)
             ~name:(schema.name ^ " Help") ~description:entry.short_description
             ~mime_type:"text/markdown" ())
  in
  let resources =
    Mcp_server.resources @ tool_help_resources
    |> List.sort (fun (a : Mcp_server.mcp_resource) b ->
           String.compare a.uri b.uri)
  in
  match TP.page_items_with_cursor ~kind:"resources" resources cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let resources_json = List.map Mcp_server.resource_to_json page in
      let result_fields =
        [ ("resources", `List resources_json) ]
        @ TP.maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      make_response ~id (`Assoc result_fields)

let handle_list_resource_templates_eio id cursor =
  let templates =
    Mcp_server.resource_templates
    |> List.sort (fun (a : Mcp_server.mcp_resource_template) b ->
           String.compare a.uri_template b.uri_template)
  in
  match TP.page_items_with_cursor ~kind:"resourceTemplates" templates cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let templates_json =
        List.map Mcp_server.resource_template_to_json page
      in
      let result_fields =
        [ ("resourceTemplates", `List templates_json) ]
        @ TP.maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      make_response ~id (`Assoc result_fields)

let handle_list_prompts_eio id cursor =
  let prompts =
    Mcp_prompt_surface.prompt_defs
    |> List.sort (fun (a : Mcp_prompt_surface.prompt_def)
                       (b : Mcp_prompt_surface.prompt_def) ->
           String.compare a.name b.name)
  in
  match TP.page_items_with_cursor ~kind:"prompts" prompts cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let prompts_json = List.map Mcp_prompt_surface.prompt_json page in
      let result_fields =
        [ ("prompts", `List prompts_json) ]
        @ TP.maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      make_response ~id (`Assoc result_fields)

let handle_get_prompt_eio state id params =
  match params with
  | None -> make_error ~id (-32602) "Missing params"
  | Some (`Assoc _ as payload) -> (
      let open Yojson.Safe.Util in
      match payload |> member "name" with
      | `String name -> (
          let arguments =
            match payload |> member "arguments" with
            | `Assoc _ as args -> args
            | `Null -> `Assoc []
            | _ -> `Assoc []
          in
          match
            Mcp_prompt_surface.get_json ~config:state.Mcp_server.room_config
              ~name ~arguments Config.raw_all_tool_schemas
          with
          | Ok json -> make_response ~id json
          | Error msg -> make_error ~id (-32602) msg)
      | _ -> make_error ~id (-32602) "Invalid params: name must be a string")
  | Some _ -> make_error ~id (-32602) "Invalid params: expected object"

let handle_resources_subscribe_eio id ?mcp_session_id params =
  let open Yojson.Safe.Util in
  match (mcp_session_id, params) with
  | None, _ -> make_error ~id (-32600) "resources/subscribe requires an MCP session"
  | Some session_id, Some (`Assoc _ as payload) -> (
      match payload |> member "uri" with
      | `String uri ->
          TC.subscribe_resource_for_session ~session_id ~uri;
          make_response ~id (`Assoc [])
      | _ -> make_error ~id (-32602) "Invalid params: uri must be a string")
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"

let handle_resources_unsubscribe_eio id ?mcp_session_id params =
  let open Yojson.Safe.Util in
  match (mcp_session_id, params) with
  | None, _ ->
      make_error ~id (-32600) "resources/unsubscribe requires an MCP session"
  | Some session_id, Some (`Assoc _ as payload) -> (
      match payload |> member "uri" with
      | `String uri ->
          TC.unsubscribe_resource_for_session ~session_id ~uri;
          make_response ~id (`Assoc [])
      | _ -> make_error ~id (-32602) "Invalid params: uri must be a string")
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"

(** {1 Request Dispatch} *)

(** Handle incoming JSON-RPC request - Pure Eio Native *)
let handle_request
    ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
    ~sw
    ~execute_tool_eio
    ~log_mcp_exn:(_log_mcp_exn : label:string -> exn -> unit)
    ~(profile : Mcp_server_eio_types.tool_profile)
    ?mcp_session_id
    ?auth_token
    state
    request_str =
  try
    let json =
      try Ok (Yojson.Safe.from_string request_str)
      with exn -> Error (Printexc.to_string exn)
    in
    match json with
    | Error msg ->
        make_error ~id:`Null ~data:(`String msg) (-32700) "Parse error"
    | Ok json ->
        if
          match json with
          | `List _ -> true
          | _ -> false
        then
          make_error ~id:`Null (-32600)
            "JSON-RPC batch requests are not supported on this MCP endpoint"
        else if is_jsonrpc_response json then
          `Null
        else if not (is_jsonrpc_v2 json) then
          make_error ~id:`Null (-32600) "Invalid Request: jsonrpc must be 2.0"
        else
        match jsonrpc_request_of_yojson json with
        | Error msg -> make_error ~id:`Null ~data:(`String msg) (-32600) "Invalid Request"
        | Ok req ->
            let id = get_id req in
            if not (is_valid_request_id id) then
              make_error ~id:`Null (-32600) "Invalid Request: id must be string, number, or null"
            else if Mcp_server.is_notification req then
              `Null
            else
                (try
                   (match req.method_ with
                   | "initialize" -> handle_initialize_eio ~profile id req.params
                   | "initialized"
                   | "notifications/initialized" -> make_response ~id `Null
                   | "resources/list" -> (
                       match TP.parse_cursor_only_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { cursor } -> handle_list_resources_eio id cursor)
                   | "resources/read" ->
                       Mcp_server_eio_resource.handle_read_resource_eio state id req.params
                   | "resources/templates/list" -> (
                       match TP.parse_cursor_only_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { cursor } ->
                           handle_list_resource_templates_eio id cursor)
                   | "resources/subscribe" ->
                       handle_resources_subscribe_eio id ?mcp_session_id req.params
                   | "resources/unsubscribe" ->
                       handle_resources_unsubscribe_eio id ?mcp_session_id req.params
                   | "prompts/list" -> (
                       match TP.parse_cursor_only_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { cursor } -> handle_list_prompts_eio id cursor)
                   | "prompts/get" -> handle_get_prompt_eio state id req.params
                   | "tools/list" -> (
                       match TP.requested_tool_list_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { names; include_hidden; include_deprecated; include_usage; mode; tier; cursor } ->
                           handle_list_tools_eio ~profile ?names ~include_hidden
                             ~include_deprecated ~include_usage ?mode ?tier ?cursor
                             state id)
                   | "tools/call" ->
                       (match req.params with
                       | Some params ->
                           (try
                             let name = Yojson.Safe.Util.(params |> member "name" |> to_string) in
                             if not (TP.tool_allowed_in_profile state profile name) then
                               make_error ~id (-32601)
                                 (Printf.sprintf
                                    "Tool '%s' is not available on this MCP endpoint."
                                    name)
                             else (
                               Printf.eprintf "[MCP] tools/call: %s (id=%s, session=%s)\n%!" name
                                 (match id with `Int i -> string_of_int i | `String s -> s | _ -> "?")
                                 (match mcp_session_id with Some s -> s | None -> "none");
                               let result =
                                 TC.handle_call_tool_eio ~execute_tool_eio
                                   ~sw ~clock ~profile ?mcp_session_id ?auth_token state id params
                               in
                               Printf.eprintf "[MCP] tools/call done: %s\n%!" name;
                               result)
                           with Yojson.Safe.Util.Type_error (_, _) ->
                             make_error ~id (-32602) "Invalid params: name must be a string")
                       | None -> make_error ~id (-32602) "Missing params")
                   | method_ -> make_error ~id (-32601) ("Method not found: " ^ method_))
                 with
                 | Invalid_argument msg
                   when TC.contains_casefold msg "invalid_argument(\"masc not initialized" ->
                     make_error ~id (-32603) (Types.masc_error_to_string Types.NotInitialized)
                   | exn ->
                       let err = Printexc.to_string exn in
                       Log.Mcp.error "Request handling failed: %s" err;
                       make_error ~id (-32603) (Printf.sprintf "Internal error: %s" err))
  with exn ->
    make_error ~id:`Null ~data:(`String (Printexc.to_string exn)) (-32603) "Internal error"

(** {1 Transport} *)

type transport_mode =
  | Framed      (* Content-Length prefixed - MCP stdio mode *)
  | LineDelimited  (* One JSON per line - simple mode *)

let detect_mode first_line =
  let lower = String.lowercase_ascii first_line in
  if String.length lower >= 14 &&
     String.sub lower 0 14 = "content-length" then
    Framed
  else
    LineDelimited

(** Read newline-delimited message from Eio flow *)
let read_line_message buf =
  try Some (Eio.Buf_read.line buf)
  with End_of_file -> None

(** Write Content-Length prefixed message to Eio flow *)
let write_framed_message flow json =
  let body = Yojson.Safe.to_string json in
  let header = Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length body) in
  Eio.Flow.copy_string header flow;
  Eio.Flow.copy_string body flow

(** Write newline-delimited message to Eio flow *)
let write_line_message flow json =
  let body = Yojson.Safe.to_string json in
  Eio.Flow.copy_string body flow;
  Eio.Flow.copy_string "\n" flow

(** Run MCP server in stdio mode with Eio *)
let run_stdio ~sw ~env ~execute_tool_eio ~log_mcp_exn state =
  let stdin = Eio.Stdenv.stdin env in
  let stdout = Eio.Stdenv.stdout env in
  let clock = Eio.Stdenv.clock env in

  Log.Mcp.info "MASC MCP Server (Eio stdio mode)";
  Log.Mcp.info "Default room: %s" Mcp_server.(state.room_config.Room.base_path);

  let buf = Eio.Buf_read.of_flow stdin ~max_size:(16 * 1024 * 1024) in

  let read_framed_message_after_first_line first_line =
    let rec read_headers acc =
      let line = Eio.Buf_read.line buf in
      if String.length line = 0 || line = "\r" then
        List.rev acc
      else
        read_headers (line :: acc)
    in
    let headers = read_headers [ first_line ] in
    let content_length =
      headers
      |> List.find_map (fun header ->
             let header = String.trim header in
             if String.length header > 16
                && String.lowercase_ascii (String.sub header 0 15)
                   = "content-length:"
             then
               let len_str =
                 String.trim
                   (String.sub header 15 (String.length header - 15))
               in
               int_of_string_opt len_str
             else
               None)
      |> Option.value ~default:0
    in
    if content_length > 0 then Some (Eio.Buf_read.take content_length buf)
    else None
  in

  let respond ~mode response =
    match response with
    | `Null -> ()
    | json -> (
        match mode with
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
        if first_line = "" then
          loop mode_opt
        else
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
          (match request_opt with
          | None ->
              Log.Mcp.info "EOF received, shutting down";
              ()
          | Some "" -> loop (Some mode)
          | Some request_str ->
              let response =
                handle_request ~clock ~sw ~execute_tool_eio ~log_mcp_exn
                  ~profile:Full ~mcp_session_id:"stdio" state
                  request_str
              in
              respond ~mode response;
              loop (Some mode))
  in

  try loop None
  with
  | End_of_file ->
      Log.Mcp.info "Connection closed"
  | exn ->
      Log.Mcp.error "Server error: %s" (Printexc.to_string exn)
