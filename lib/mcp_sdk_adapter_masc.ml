module MP = Mcp_protocol
module Handler = Mcp_protocol_eio.Handler
module TP = Mcp_server_eio_tool_profile

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

let sdk_owned_methods =
  [
    "ping";
  ]

let handles_method method_ =
  List.mem method_ sdk_owned_methods

let instructions_for_profile = function
  | Full -> TP.default_instructions
  | Managed_agent -> TP.managed_agent_instructions
  | Operator_remote -> TP.operator_remote_instructions

let jsonrpc_notification = Mcp_transport_protocol.jsonrpc_notification

let make_context ?mcp_session_id () : Handler.context =
  let send_notification ~method_ ~params =
    (match mcp_session_id with
    | Some session_id ->
        Sse.send_to session_id (jsonrpc_notification ?params method_)
    | None -> ());
    Ok ()
  in
  let send_log (level : MP.Logging.log_level) message =
    let params =
      `Assoc [
        ("level", `String (MP.Logging.log_level_to_string level));
        ("data", `String message);
      ]
    in
    send_notification ~method_:"notifications/message" ~params:(Some params)
  in
  let send_progress ~token ~progress ~message ~total =
    let params =
      MP.Mcp_result.progress_to_yojson
        {
          MP.Mcp_result.progress_token = token;
          progress;
          total;
          message;
        }
    in
    send_notification ~method_:MP.Notifications.progress ~params:(Some params)
  in
  {
    send_notification;
    send_log;
    send_progress;
    request_sampling =
      (fun _ -> Error "sampling/createMessage is not available on this MASC transport");
    request_roots_list = (fun () -> Ok []);
    request_elicitation =
      (fun _ -> Error "elicitation/create is not available on this MASC transport");
  }

let response_result = function
  | `Assoc fields -> List.assoc_opt "result" fields
  | _ -> None

let response_error_message = function
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`Assoc err_fields) -> (
          match List.assoc_opt "message" err_fields with
          | Some (`String message) -> Some message
          | _ -> None)
      | _ -> None)
  | _ -> None

let parse_list parser field_name = function
  | `Assoc fields -> (
      match List.assoc_opt field_name fields with
      | Some (`List items) ->
          List.fold_left
            (fun acc item ->
              match acc, parser item with
              | Ok items, Ok parsed -> Ok (parsed :: items)
              | Error msg, _ | _, Error msg -> Error msg)
            (Ok []) items
          |> Result.map List.rev
      | _ -> Error ("Missing " ^ field_name))
  | _ -> Error "Invalid response payload"

let tool_result_of_response response =
  match response_result response with
  | Some result -> (
      match MP.Mcp_types.tool_result_of_yojson result with
      | Ok parsed -> Ok parsed
      | Error msg -> Error msg)
  | None -> (
      match response_error_message response with
      | Some message -> Ok (MP.Mcp_types.tool_result_of_error message)
      | None -> Error "Missing tools/call result")

let resource_contents_of_response response =
  match response_result response with
  | Some result -> parse_list MP.Mcp_types.resource_contents_of_yojson "contents" result
  | None -> (
      match response_error_message response with
      | Some message -> Error message
      | None -> Error "Missing resources/read result")

let sdk_tool_of_schema profile (schema : Masc_domain.tool_schema) =
  let annotations =
    match TP.tool_annotations_for_profile profile schema.name with
    | None -> None
    | Some json -> (
        match MP.Mcp_types.tool_annotations_of_yojson json with
        | Ok parsed -> Some parsed
        | Error _ -> None)
  in
  MP.Mcp_types.make_tool
    ~name:schema.name
    ~description:schema.description
    ~title:(TP.tool_title_of_name schema.name)
    ~input_schema:schema.input_schema
    ?annotations
    ?output_schema:(TP.tool_output_schema_field schema.name)
    ()

let public_tool_help_schemas () =
  Config.visible_tool_schemas ()

let tool_help_resources () =
  public_tool_help_schemas ()
  |> List.sort (fun (a : Masc_domain.tool_schema) (b : Masc_domain.tool_schema) ->
         String.compare a.name b.name)
  |> List.map (fun (schema : Masc_domain.tool_schema) ->
         let entry = Tool_help_registry.entry_of_schema schema in
         Mcp_server.make_resource ~uri:("masc://tool-help/" ^ schema.name)
           ~name:(schema.name ^ " Help") ~description:entry.short_description
           ~mime_type:"text/markdown" ())

let sdk_resource_of_local (resource : Mcp_server.mcp_resource) =
  MP.Mcp_types.make_resource
    ~uri:resource.uri
    ~name:resource.name
    ~description:resource.description
    ~mime_type:resource.mime_type
    ()

let sdk_resource_template_of_local
    (template : Mcp_server.mcp_resource_template) : MP.Mcp_types.resource_template =
  {
    uri_template = template.uri_template;
    name = template.name;
    title = None;
    description = Some template.description;
    mime_type = Some template.mime_type;
    icon = None;
  }

let sdk_prompt_of_local (prompt : Mcp_prompt_surface.prompt_def) =
  let arguments =
    prompt.arguments
    |> List.map (fun (arg : Mcp_prompt_surface.prompt_argument) ->
           {
             MP.Mcp_types.name = arg.name;
             description = Some arg.description;
             required = Some arg.required;
           })
  in
  MP.Mcp_types.make_prompt
    ~name:prompt.name
    ~description:prompt.description
    ~arguments
    ()

let create_handler
    ~handle_call_tool_eio
    ~state
    ~profile
    ~sw
    ~clock
    ?mcp_session_id
    ?auth_token
    () =
  let handler =
    Handler.create
      ~name:"masc-mcp"
      ~version:Version.version
      ~instructions:(instructions_for_profile profile)
      ()
  in
  let handler =
    TP.tool_schemas_for_profile state profile
    |> List.sort (fun (a : Masc_domain.tool_schema) (b : Masc_domain.tool_schema) ->
           String.compare a.name b.name)
    |> List.fold_left
         (fun acc (schema : Masc_domain.tool_schema) ->
           let tool = sdk_tool_of_schema profile schema in
           Handler.add_tool tool
             (fun _ctx _name arguments ->
               let params =
                 `Assoc
                   [
                     ("name", `String schema.name);
                     ( "arguments",
                       match arguments with Some value -> value | None -> `Null );
                   ]
               in
               handle_call_tool_eio ~sw ~clock ~profile ?mcp_session_id
                 ?auth_token state (`Int 0) params
               |> tool_result_of_response)
             acc)
         handler
  in
  let resources =
    (Mcp_server.resources @ tool_help_resources ())
    |> List.sort (fun (a : Mcp_server.mcp_resource) b ->
           String.compare a.uri b.uri)
  in
  let handler =
    List.fold_left
      (fun acc resource ->
        Handler.add_resource
          (sdk_resource_of_local resource)
          (fun _ctx uri ->
            Mcp_server_eio_resource.handle_read_resource_eio state (`Int 0)
              (Some (`Assoc [ ("uri", `String uri) ]))
            |> resource_contents_of_response)
          acc)
      handler resources
  in
  let handler =
    Mcp_server.resource_templates
    |> List.sort (fun (a : Mcp_server.mcp_resource_template) b ->
           String.compare a.uri_template b.uri_template)
    |> List.fold_left
         (fun acc template ->
           Handler.add_resource_template
             (sdk_resource_template_of_local template)
             (fun _ctx uri ->
               Mcp_server_eio_resource.handle_read_resource_eio state (`Int 0)
                 (Some (`Assoc [ ("uri", `String uri) ]))
               |> resource_contents_of_response)
             acc)
         handler
  in
  Mcp_prompt_surface.prompt_defs
  |> List.sort (fun (a : Mcp_prompt_surface.prompt_def)
                     (b : Mcp_prompt_surface.prompt_def) ->
         String.compare a.name b.name)
  |> List.fold_left
       (fun acc prompt ->
         Handler.add_prompt
           (sdk_prompt_of_local prompt)
           (fun _ctx _name arguments ->
             let args_json =
               `Assoc
                 (List.map (fun (key, value) -> (key, `String value)) arguments)
             in
             match
               Mcp_prompt_surface.get_json ~config:state.Mcp_server.room_config
                 ~name:prompt.name ~arguments:args_json
                 Config.raw_all_tool_schemas
             with
             | Ok json -> MP.Mcp_types.prompt_result_of_yojson json
             | Error _ as err -> err)
           acc)
       handler

let dispatch_ping ~id =
  Some (Mcp_transport_protocol.make_response ~id (`Assoc []))

let dispatch_request
    ~handle_call_tool_eio:_
    ~state:_
    ~profile:_
    ~sw:_
    ~clock:_
    ?mcp_session_id:_
    ?auth_token:_
    (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      let id =
        match List.assoc_opt "id" fields with
        | Some id -> id
        | None -> `Null
      in
      let method_ =
        match List.assoc_opt "method" fields with
        | Some (`String m) -> m
        | _ -> ""
      in
      (match method_ with
      | "ping" -> dispatch_ping ~id
      | _ -> None)
  | _ -> None
