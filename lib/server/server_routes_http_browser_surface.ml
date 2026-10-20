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
   cannot choose a private installation or provide a control envelope. *)
let command ~config ~principal arguments =
  let reserved=List.map (fun (schema:Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas in
  let result=Result.bind (Browser_addon_host.connect ~config
    ~access:Lane_addon_sources.Unauthenticated ~principal ~reserved)
    (fun host -> Browser_addon_host.call host ~arguments) in
  match result with
  | Ok result -> Mcp_protocol.Mcp_types.tool_result_to_yojson result
  | Error error ->
      let class_,effect_disposition,message=match error with
        | Lane_addon_runtime.Unavailable message -> Tool_result.Dependency_unavailable,Tool_result.Proven_pre_effect,message
        | Outcome_unknown message -> Tool_result.Runtime_failure,Tool_result.Effect_outcome_unknown,message
        | Host_refusal refusal ->
            let class_,message=match refusal with
              | Lane_addon_call_context.Rejected message|Activity_disabled message -> Tool_result.Workflow_rejection,message
              | Unavailable message|Activity_unobserved message -> Tool_result.Dependency_unavailable,message in
            class_,Tool_result.Proven_pre_effect,message in
      let failure=Tool_result.make_err ~tool_name:Browser_addon_tool.definition.name
        ~start_time:(Tool_timing.start ()) ~class_ ~effect_disposition message in
      Mcp_protocol.Mcp_types.tool_result_to_yojson {
        content=[TextContent {type_="text";text=message;annotations=None}];
        is_error=Some true;structured_content=None;_meta=Lane_addon_tool_result.metadata failure}
(* The same choice policy serves the UI and Keeper tools. Selection itself
   never opens, navigates or closes a browser. *)
let server_selection ~verb fields =
  let input = `Assoc (List.filter (fun (key,_) -> List.mem key ["lane";"clientId";"tabId"]) fields) in
  Result.bind (Browser_surface.parse_request input) (fun request ->
    let bound = match verb with
      | Browser_lane.Session_close | Browser_lane.Page_goto _ -> true
      | Browser_lane.Session_open _ | Browser_lane.Session_status | Browser_lane.Tabs_list
      | Browser_lane.Page_read _ | Browser_lane.Page_document _ | Browser_lane.Page_downloads _
      | Browser_lane.Page_capture _ | Browser_lane.Page_scene _ | Browser_lane.Page_interact _
      | Browser_lane.Page_elements _ | Browser_lane.Page_act _ | Browser_lane.Page_context _
      | Browser_lane.Page_instruct _ | Browser_lane.Page_locate _ | Browser_lane.Page_extract _ ->
        Option.is_some request.tab_id in
    Result.bind (Browser_selection.resolve ~verb ~bound request.route
      |> Result.map_error Browser_selection.error_message) (fun selected ->
      match selected.route with
      | Browser_lane.Automation_route -> Ok (selected, Browser_lane.Server_automation)
      | Browser_lane.Stagehand_route -> Ok (selected, Browser_lane.Server_stagehand)
      | Browser_lane.Live_route _ -> Error ("Use a work browser for session management or navigation; " ^ Browser_lane.server_lane_refused)))
let server_command ~verb ~timeout_sec fields =
  Result.bind (server_selection ~verb fields) (fun (selected,lane) ->
    Browser_lane.issue_server_lane lane ~verb ~timeout_sec
    |> Browser_surface.decode_answer ~lane:(Browser_lane.server_lane_name lane)
    |> Result.map (function
      | `Assoc data -> `Assoc (["browserSelection",Browser_selection.to_json selected;
          "lane",`String (Browser_lane.Lane_name.to_wire (Browser_lane.server_lane_name lane))]
          @ List.filter (fun (key,_) -> not (List.mem key ["browserSelection";"lane"])) data)
      | value -> value))
let session = function
  | `Assoc fields ->
    let headless = match List.assoc_opt "headless" fields with
      | None -> Ok (Some false) | Some (`Bool value) -> Ok (Some value)
      | _ -> Error "headless must be boolean" in
    (match headless, List.assoc_opt "action" fields with
     | Error detail, _ -> Error detail
     | Ok headless, Some (`String "open") ->
       server_command ~verb:(Browser_lane.Session_open {headless}) ~timeout_sec:60. fields
     | Ok _, Some (`String "close") ->
       server_command ~verb:Browser_lane.Session_close ~timeout_sec:60. fields
     | Ok _, _ -> Error "action must be open or close")
  | _ -> Error "body must be an object"
let goto = function
  | `Assoc fields ->
    (match List.assoc_opt "url" fields, List.assoc_opt "tabId" fields with
     | Some (`String url), tab ->
       let tab_id = match tab with
         | None -> Ok None | Some (`Int id) when id >= 0 -> Ok (Some id)
         | Some _ -> Error "tabId must be a nonnegative integer" in
       Result.bind tab_id (fun tab_id ->
         let uri = Uri.of_string url in
         match Uri.scheme uri, Uri.host uri with
         | Some ("http" | "https"), Some host when host <> "" ->
           server_command ~verb:(Browser_lane.Page_goto {url;tab_id}) ~timeout_sec:60. fields
         | _ -> Error "url must be an absolute HTTP(S) URL")
     | (Some _ | None), _ -> Error "url is required")
  | _ -> Error "body must be an object"
(* What the connection list answers. The connected clients are this server's
   own list. The BiDi host's state is that host's record on disk, which also
   says why a host that is not in the list ended. *)
let clients_listing ~base_path =
  let host = Browser_bidi_host_status.observe ~base_path ~configuration:(Runtime.browser_configuration ()) in
  (* The list the report was made from, so the two say of one list. *)
  let clients = Browser_bidi_host_status.listed_clients host in
  let snapshot = { (Browser_selection.snapshot ()) with live_clients=clients } in
  let decision verb = match Browser_selection.choose ~verb ~bound:false ~snapshot Browser_selection.Automatic with
    | Ok selected -> `Assoc ["ok",`Bool true;"data",Browser_selection.to_json selected]
    | Error error -> `Assoc ["ok",`Bool false;"error",Browser_selection.error_to_json error] in
  `Assoc
    [ "clients", `List (List.map Browser_lane.client_json clients)
    ; "bidiHost", Browser_bidi_host_status.to_json host
    ; "automatic", `Assoc ["browse",decision Browser_lane.Tabs_list;
        "work",decision (Browser_lane.Session_open {headless=Some false})] ]
let add_routes router =
  router
  |> Http.Router.post "/api/v1/dashboard/browser-lane/command"
      (with_token_permission_auth ~permission:Masc_domain.CanAdmin (fun state agent_name request reqd ->
         let config=Mcp_server.workspace_config state in
         read_body request reqd (fun arguments -> Ok (command ~config
           ~principal:(Lane_addon_call_context.Host_actor agent_name) arguments))))
  |> Http.Router.get "/api/v1/dashboard/browser-lane/clients"
      (with_permission_auth ~permission:Masc_domain.CanReadState (fun state request reqd ->
         reply request reqd
           (Ok (clients_listing ~base_path:(Mcp_server.workspace_config state).base_path))))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/read"
      (with_permission_auth ~permission:Masc_domain.CanReadState (fun _state request reqd ->
         read_body request reqd (fun json ->
           Result.bind (Browser_surface.parse_request json) (fun surface_request ->
             Browser_surface.read surface_request |> Result.map_error Browser_surface.failure_message))))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/scene"
      (with_permission_auth ~permission:Masc_domain.CanReadState (fun _state request reqd ->
         read_body request reqd Browser_scene.read_request))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/screenshot"
      (with_permission_auth ~permission:Masc_domain.CanReadState (fun _state request reqd ->
         read_body request reqd (fun json ->
           Result.bind (Browser_surface.parse_capture_request json) (fun surface_request ->
             Browser_surface.capture surface_request |> Result.map_error Browser_surface.failure_message))))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/interact"
      (with_token_permission_auth ~permission:Masc_domain.CanAdmin (fun _state _agent_name request reqd ->
         read_body request reqd (fun json ->
           Result.bind (Browser_interaction.parse json) Browser_interaction.perform)))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/session"
      (with_token_permission_auth ~permission:Masc_domain.CanAdmin (fun _state _agent_name request reqd ->
         read_body request reqd session))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/goto"
      (with_token_permission_auth ~permission:Masc_domain.CanAdmin (fun _state _agent_name request reqd ->
         read_body request reqd goto))
