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
let session = function
  | `Assoc fields ->
    let headless = match List.assoc_opt "headless" fields with
      | None -> Ok None | Some (`Bool value) -> Ok (Some value)
      | _ -> Error "headless must be boolean" in
    (match headless, List.assoc_opt "action" fields with
     | Error detail, _ -> Error detail
     | Ok headless, Some (`String "open") ->
       Browser_lane.issue ~lane_name:"automation" ~verb:(Browser_lane.Session_open {headless}) ~timeout_sec:60.
       |> Browser_surface.decode_answer
     | Ok _, Some (`String "close") ->
       Browser_lane.issue ~lane_name:"automation" ~verb:Browser_lane.Session_close ~timeout_sec:60.
       |> Browser_surface.decode_answer
     | _ -> Error "action must be open or close")
  | _ -> Error "body must be an object"
let goto = function
  | `Assoc fields ->
    (match List.assoc_opt "url" fields with
     | Some (`String url) ->
       let uri = Uri.of_string url in
       (match Uri.scheme uri, Uri.host uri with
        | Some ("http" | "https"), Some host when host <> "" ->
          Browser_lane.issue ~lane_name:"automation" ~verb:(Browser_lane.Page_goto {url}) ~timeout_sec:60.
          |> Browser_surface.decode_answer
        | _ -> Error "url must be an absolute HTTP(S) URL")
     | _ -> Error "url is required")
  | _ -> Error "body must be an object"
let add_routes router =
  router
  |> Http.Router.post "/api/v1/dashboard/browser-lane/read"
      (with_permission_auth ~permission:Masc_domain.CanReadState (fun _state request reqd ->
         read_body request reqd (fun json ->
           Result.bind (Browser_surface.parse_request json) Browser_surface.read)))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/session"
      (with_token_permission_auth ~permission:Masc_domain.CanAdmin (fun _state request reqd ->
         read_body request reqd session))
  |> Http.Router.post "/api/v1/dashboard/browser-lane/goto"
      (with_token_permission_auth ~permission:Masc_domain.CanAdmin (fun _state request reqd ->
         read_body request reqd goto))
