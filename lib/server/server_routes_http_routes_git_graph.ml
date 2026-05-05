module Http = Http_server_eio

open Server_auth

let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some value when value <> "" -> Some value
  | _ -> None

let add_routes router =
  router
  |> Http.Router.get "/api/v1/git/graph" (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           let limit =
             Server_utils.int_query_param req "n" ~default:120
             |> Server_utils.clamp ~min_v:20 ~max_v:500
           in
           let base_path = state.Mcp_server.room_config.base_path in
           let repo_id = trimmed_query_param req "repo_id" in
           let json =
             match repo_id with
             | None ->
               Git_graph_snapshot.dashboard_http_json
                 ~config:state.Mcp_server.room_config ~limit ()
             | Some id -> (
                 match Repo_store.find ~base_path id with
                 | Ok repo ->
                   Git_graph_snapshot.dashboard_http_json
                     ~repo_id:id
                     ~repo_label:repo.Repo_manager_types.name
                     ~repo_root:(Repo_store.local_path ~base_path repo)
                     ~config:state.Mcp_server.room_config
                     ~limit ()
                 | Error msg ->
                   Git_graph_snapshot.empty_json msg)
           in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd)
         request reqd)
