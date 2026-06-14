(** Dashboard HTTP handler bodies, extracted from
    [server_routes_http_routes_dashboard.ml]. Holds the four
    request-handler bodies wired into the route table: agent broadcast,
    link previews, task history, and workspace timeline. *)

module Http = Http_server_eio

let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s

(* Duplicated locally to avoid sibling -> parent cycle. The parent file
   keeps its own copy because three sites there call it; both copies
   are identical 4-line helpers. *)
let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some value when value <> "" -> Some value
  | _ -> None
;;

let handle_broadcast state agent_name reqd body_str =
  let reply ok error_opt =
    let fields = [ ("ok", `Bool ok) ] in
    let fields = match error_opt with
      | Some msg -> fields @ [ ("error", `String msg) ]
      | None -> fields
    in
    Http.Response.json_value (`Assoc fields) reqd
  in
  try
    let json = Yojson.Safe.from_string body_str in
    match Json_util.assoc_member_opt "message" json with
    | Some (`String message) ->
        let config = (Mcp_server.workspace_config state) in
        let _ = Workspace.broadcast config ~from_agent:agent_name ~content:message in
        reply true None
    | Some `Null -> reply false (Some "missing required field: message")
    | None | Some _ -> reply false (Some "field 'message' must be a string")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Yojson.Json_error msg -> reply false (Some ("invalid JSON: " ^ msg))
  | e -> reply false (Some (Printexc.to_string e))

let handle_dashboard_link_previews state req reqd body_str =
  let respond_error message =
    Http.Response.json_value ~status:`Bad_request ~request:req
      (`Assoc
         [
           ("ok", `Bool false);
           ("error", `String message);
         ])
      reqd
  in
  try
    let args = Yojson.Safe.from_string body_str in
    match
      Server_dashboard_http_link_preview.dashboard_link_previews_http_json
        ~state ~args
    with
    | Ok json ->
        Http.Response.json_value ~compress:true ~request:req json reqd
    | Error message -> respond_error message
  with Yojson.Json_error message ->
    respond_error ("invalid json: " ^ message)

let handle_dashboard_task_history state req reqd =
  let task_id =
    match Server_utils.query_param req "task_id" with
    | Some value -> String.trim value
    | None -> ""
  in
  if task_id = "" then
    Http.Response.json_value ~status:`Bad_request ~request:req
      (`Assoc [ ("error", `String "task_id is required") ])
      reqd
  else
    let limit =
      Server_utils.int_query_param req "limit" ~default:50
      |> Server_utils.clamp ~min_v:1 ~max_v:200
    in
    let cache_key =
      Printf.sprintf "task_history:%s:%s:%d"
        (Mcp_server.workspace_config state).base_path task_id limit
    in
    let json =
      Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
        Domain_pool_ref.submit_io_or_inline (fun () ->
          Task.Tool.task_history_events_json (Mcp_server.workspace_config state)
            ~task_id ~limit))
    in
    Http.Response.json_value ~compress:true ~request:req json reqd

let handle_dashboard_workspace state req reqd =
  let limit =
    Server_utils.int_query_param req "limit" ~default:50
    |> Server_utils.clamp ~min_v:1 ~max_v:200
  in
  let me =
    match trimmed_query_param req "me" with
    | Some _ as value -> value
    | None -> trimmed_query_param req "agent"
  in
  (* Dashboard_workspace.json queries up to ~1000 messages from Workspace per request
     (uncached, ~4.7s measured solo; under a parallel dashboard burst it held
     the single Eio HTTP domain and dragged co-fired requests to ~3.4s). Cache
     + offload via respond_cached_read; cache_key carries limit + actor so
     param variants stay distinct. Shared by /dashboard/workspace and /workspaces. *)
  let cache_key =
    Printf.sprintf "workspace:%s:%d:%s"
      (Mcp_server.workspace_config state).base_path limit
      (Option.value ~default:"" me)
  in
  Server_routes_http_common.respond_cached_read ~request:req ~reqd ~cache_key
    ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s (fun () ->
      Dashboard_workspace.json ~config:(Mcp_server.workspace_config state) ?me ~limit ())
