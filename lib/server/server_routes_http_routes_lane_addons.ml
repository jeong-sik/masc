open Server_auth
module Http = Http_server_eio
module Runtime = Lane_addon_runtime

let ( let* ) = Result.bind
let error_json message = `Assoc ["error", `String message]
let decode_body body =
  try match Yojson.Safe.from_string body with
    | `Assoc fields as json ->
        let names = List.map fst fields in
        if List.length names = List.length (List.sort_uniq String.compare names)
        then Ok json else Error "duplicate request field"
    | _ -> Error "request body must be a JSON object"
  with Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)

let decode_slice_query fields =
  let names = List.map fst fields in
  if List.length names <> List.length (List.sort_uniq String.compare names)
  then Error "duplicate query field"
  else
    let rec parse acc = function
      | [] -> Ok (`Assoc (List.rev acc))
      | (name, value) :: rest ->
          let* parsed = match name with
            | "run_id" | "lane_id" ->
                if String.trim value = "" then Error (name ^ " must not be blank")
                else Ok (`String value)
            | "since" | "until" ->
                (match float_of_string_opt value with
                 | Some value when Float.is_finite value -> Ok (`Float value)
                 | Some _ | None -> Error (name ^ " must be finite Unix seconds"))
            | _ -> Error ("unknown slice parameter: " ^ name) in
          parse ((name, parsed) :: acc) rest
    in
    let* json = parse [] fields in
    match json with
    | `Assoc fields ->
        (match List.assoc_opt "since" fields, List.assoc_opt "until" fields with
         | Some (`Float since), Some (`Float until) when since > until -> Error "since must be <= until"
         | _ -> Ok json)
    | _ -> Error "slice query must be an object"

let respond request reqd = function
  | Ok json -> respond_json_value_with_cors request reqd json
  | Error detail -> respond_json_value_with_cors ~status:`Bad_request request reqd (error_json detail)

let dispatch ?caller state operation args =
  Runtime.dispatch ?caller ~config:(Mcp_server.workspace_config state) ~operation args
  |> Result.map_error Runtime.error_to_string

let query_fields request =
  Uri.query (Uri.of_string request.Httpun.Request.target)
  |> List.concat_map (fun (name, values) ->
       match values with [] -> [name, ""] | values -> List.map (fun value -> name, value) values)

let decode_inspect_query = function
  | [] -> Ok (`Assoc [])
  | ["instance_id", id] when String.trim id <> "" -> Ok (`Assoc ["instance_id", `String id])
  | _ -> Error "inspect accepts one non-blank instance_id or no parameters"

let get_inspect request reqd =
  with_read_auth (fun state _request reqd ->
    let result = let* args = decode_inspect_query (query_fields request) in
      dispatch state Runtime.Inspect args in
    respond request reqd result) request reqd

let get_slice request reqd =
  with_read_auth (fun state _request reqd ->
    let result = let* args = decode_slice_query (query_fields request) in dispatch state Runtime.Slice args in
    respond request reqd result) request reqd

let get_action request reqd =
  with_read_auth (fun state _request reqd ->
    let result =
      let fields = query_fields request |> List.sort (fun (a, _) (b, _) -> String.compare a b) in
      let* args = match fields with
        | ["instance_id", instance_id; "request_id", request_id]
            when String.trim instance_id <> "" && String.trim request_id <> "" ->
            Ok (`Assoc ["instance_id", `String instance_id; "request_id", `String request_id])
        | _ -> Error "action status requires exactly instance_id and request_id" in
      dispatch state Runtime.Action_status args in
    respond request reqd result) request reqd

let post ~operation ~tool_name request reqd =
  with_tool_actor_auth ~tool_name (fun state caller _request reqd ->
    Http.Request.read_body_async reqd (fun body ->
      let result = let* args = decode_body body in dispatch ~caller state operation args in
      respond request reqd result)) request reqd

let respond_declaration request reqd = function
  | Ok json -> respond_json_value_with_cors request reqd json
  | Error (error : Lane_addon_declaration.error) ->
      let status = match error.code with
        | Invalid_request | Invalid_declaration -> `Bad_request
        | Not_found -> `Not_found | Revision_conflict -> `Conflict | Io_error -> `Internal_server_error in
      respond_json_value_with_cors ~status request reqd (Lane_addon_declaration.error_to_json error)

let read_declaration request reqd =
  with_tool_actor_auth ~tool_name:"masc_lane_declaration_read" (fun state _caller _request reqd ->
    let args = `Assoc (List.map (fun (key,value) -> key,`String value) (query_fields request)) in
    respond_declaration request reqd (Runtime.read_declaration ~config:(Mcp_server.workspace_config state) args)) request reqd

let save_declaration request reqd =
  with_tool_actor_auth ~tool_name:"masc_lane_declaration_save" (fun state _caller _request reqd ->
    Http.Request.read_body_async reqd (fun body ->
      let result = match decode_body body with
        | Error message -> Error {Lane_addon_declaration.code=Invalid_request;message;current=None}
        | Ok args -> Runtime.save_declaration ~config:(Mcp_server.workspace_config state) args in
      respond_declaration request reqd result)) request reqd

let register_delivery ~sw ~clock =
  Runtime.register_delivery_handler (fun ~config ~caller ~keeper_name ~prompt ->
    match current_server_state () with
    | None -> Error "server state is unavailable for Keeper evidence delivery"
    | Some state ->
        let current_config = Mcp_server.workspace_config state in
        if not (String.equal config.Workspace.base_path current_config.Workspace.base_path)
        then Error "evidence belongs to a different workspace"
        else
          let context : _ Keeper_tool_surface.context = {
            config; agent_name = caller; sw; clock;
            proc_mgr = state.Mcp_server.proc_mgr; net = state.Mcp_server.net;
            publication_recovery_provider = Mcp_server.publication_recovery_availability_provider state;
          } in
          let* message = Keeper_invocation_contract.direct_message
            ~keeper_name ~prompt ~direct_reply:true
            ~surface_context:(`Assoc ["kind", `String "lane_addon_evidence"; "optional", `Bool true])
            ~channel:"" ~user_blocks:[] ~attachments:[] ()
            |> Result.map_error Keeper_invocation_contract.request_error_to_string in
          let result = Keeper_tool_surface.dispatch_keeper_msg ~submitted_by:caller context ~message in
          match result with
          | Tool_result.Completed _ | Tool_result.Deferred _ -> Ok (Tool_result.to_json result)
          | Tool_result.Failed failure -> Error failure.message)

let add_routes ~sw ~clock router =
  register_delivery ~sw ~clock;
  router
  |> Http.Router.get "/api/v1/lane-addons/declaration" read_declaration
  |> Http.Router.post "/api/v1/lane-addons/declaration" save_declaration
  |> Http.Router.get "/api/v1/lane-addons" get_inspect
  |> Http.Router.get "/api/v1/lane-addons/slice" get_slice
  |> Http.Router.get "/api/v1/lane-addons/actions" get_action
  |> Http.Router.post "/api/v1/lane-addons/actions" (post ~operation:Runtime.Act ~tool_name:"masc_lane_act")
  |> Http.Router.post "/api/v1/lane-addons/attach" (post ~operation:Runtime.Attach ~tool_name:"masc_lane_attach")
  |> Http.Router.post "/api/v1/lane-addons/observe" (post ~operation:Runtime.Observe ~tool_name:"masc_lane_observe")
  |> Http.Router.post "/api/v1/lane-addons/detach" (post ~operation:Runtime.Detach ~tool_name:"masc_lane_detach")
  |> Http.Router.post "/api/v1/lane-addons/evidence" (post ~operation:Runtime.Evidence ~tool_name:"masc_lane_evidence")
