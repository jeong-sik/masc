open Server_auth
module Http = Http_server_eio
let reply request reqd = function
  | Ok data -> respond_json_value_with_cors request reqd
      (`Assoc ["ok",`Bool true;"data",data])
  | Error error -> respond_json_value_with_cors ~status:`Bad_request request reqd
      (`Assoc ["ok",`Bool false;"error",`String error])
let read_body request reqd f =
  Http.Request.read_body_async reqd (fun body ->
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error detail -> reply request reqd (Error detail)
    | json -> reply request reqd (f json))
(* Public browser commands enter the same advertised-tool middleware as Keeper
   calls. The HTTP authorization boundary supplies the actor; request fields
   cannot choose a private installation or provide a control envelope. The
   host chooses the browser before the worker runs the command. *)
let command ~config ~principal arguments =
  let reserved=List.map (fun (schema:Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas in
  let failed failure=Mcp_protocol.Mcp_types.tool_result_to_yojson {
    content=[TextContent {type_="text";text=Tool_result.message failure;annotations=None}];
    is_error=Some true;structured_content=(match Tool_result.data failure with `Null -> None | data -> Some data);
    _meta=Lane_addon_tool_result.metadata failure} in
  match Browser_addon_host.connect ~config ~access:Lane_addon_sources.Unauthenticated ~principal ~reserved with
  | Error error -> failed (Browser_addon_host.error_result ~start_time:(Tool_timing.start ()) error)
  | Ok host -> match Browser_addon_host.command host ~arguments with
    | Ok result -> Mcp_protocol.Mcp_types.tool_result_to_yojson result
    | Error failure -> failed failure
(* The dashboard's browser views see the browser Add-on as an
   unauthenticated caller does, Shared installations only, since the
   CanReadState routes among them serve any read-state caller. *)
let view_access=Lane_addon_sources.Unauthenticated
let shared_host ~config ~principal =
  let reserved=List.map (fun (schema:Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas in
  Browser_addon_host.connect ~config ~access:view_access ~principal ~reserved
let view ~config ~principal operation json =
  let start_time=Tool_timing.start () in
  match shared_host ~config ~principal with
  | Ok host -> operation host json
  | Error error -> Browser_addon_host.error_result ~start_time error
(* The manual BiDi host record is on this server's disk, not in the Add-on
   worker: it is read here and answered beside the Add-on's clients, where the
   TUI connection list reads it. It reads the Add-on with the access the
   clients do, so the response never names an installation they cannot see. *)
let clients_listing ~config =
  let bidi_host=Browser_bidi_host_status.observe ~access:view_access
    ~base_path:config.Workspace.base_path
    ~configuration:(Runtime.browser_configuration ()) in
  Browser_addon_view.connection_inventory ~config ~access:view_access ~bidi_host
let reply_view request reqd result = match result with
  | Tool_result.Completed _ -> respond_json_value_with_cors request reqd
      (`Assoc ["ok",`Bool true;"data",Tool_result.data result])
  | Deferred _ -> respond_json_value_with_cors ~status:`Accepted request reqd
      (`Assoc ["ok",`Bool false;"status",`String "deferred";"error",`String "browser operation is deferred";
        "data",Tool_result.to_json result])
  | Failed failure ->
      let status=match failure.class_ with
        | Tool_result.Dependency_unavailable -> `Service_unavailable
        | Runtime_failure -> `Bad_gateway
        | Policy_rejection|Workflow_rejection|Operator_cancelled -> `Bad_request in
      respond_json_value_with_cors ~status request reqd (`Assoc (["ok",`Bool false;
        "error",`String failure.message;"data",Tool_result.data result]
        @ match Lane_addon_tool_result.metadata result with None -> []|Some meta -> ["_meta",meta]))
let read_view_body ~config ~principal operation request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let result=match Yojson.Safe.from_string body with
      | exception Yojson.Json_error detail -> Tool_result.make_err
          ~tool_name:Browser_addon_tool.definition.name ~start_time:(Tool_timing.start ())
          ~class_:Tool_result.Policy_rejection ~effect_disposition:Tool_result.Proven_pre_effect detail
      | json -> view ~config ~principal operation json in
    reply_view request reqd result)
let add_routes router =
  let read operation state request reqd =
    read_view_body ~config:(Mcp_server.workspace_config state)
      ~principal:Lane_addon_call_context.Operator operation request reqd in
  let write operation state actor request reqd =
    read_view_body ~config:(Mcp_server.workspace_config state)
      ~principal:(Lane_addon_call_context.Host_actor actor) operation request reqd in
  router
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/browser-lane/command"
      (fun state agent_name request reqd ->
         let config=Mcp_server.workspace_config state in
         read_body request reqd (fun arguments -> Ok (command ~config
           ~principal:(Lane_addon_call_context.Host_actor agent_name) arguments)))
  |> Server_route.get (Server_route.Permission Masc_domain.CanReadState) "/api/v1/dashboard/browser-lane/clients"
      (fun state request reqd ->
         reply_view request reqd (clients_listing ~config:(Mcp_server.workspace_config state)))
  |> Server_route.post (Server_route.Permission Masc_domain.CanReadState) "/api/v1/dashboard/browser-lane/read"
      (read Browser_addon_view.read)
  |> Server_route.post (Server_route.Permission Masc_domain.CanReadState) "/api/v1/dashboard/browser-lane/scene"
      (read Browser_addon_view.scene)
  |> Server_route.post (Server_route.Permission Masc_domain.CanReadState) "/api/v1/dashboard/browser-lane/screenshot"
      (read Browser_addon_view.capture)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/browser-lane/interact"
      (write Browser_addon_view.interact)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/browser-lane/session"
      (write Browser_addon_view.session)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/browser-lane/goto"
      (write Browser_addon_view.goto)
