open Server_auth
open Server_utils
open Server_routes_http_pages

module Http = Http_server_eio

let base_path_of_state state = state.Mcp_server.room_config.base_path

let json_error message =
  `Assoc [("ok", `Bool false); ("error", `String message)]

let json_response ~status req reqd json =
  Http.Response.json ~status ~request:req
    (Yojson.Safe.to_string json) reqd

let safe_path base requested =
  (* Extremely naive safe path check for prototype *)
  let full = Filename.concat base requested in
  if String.starts_with ~prefix:base full then full else base

let add_routes router =
  router
  |> Http.Router.get "/api/v1/workspace/tree" (fun request reqd ->
       match get_server_state_result () with
       | Error message -> json_response ~status:`Internal_server_error request reqd (json_error message)
       | Ok state ->
           let base = base_path_of_state state in
           (* For prototype, we just return a mock or a tiny real listing *)
           let get_tree dir =
             if not (Sys.file_exists dir) then []
             else
               let files = Sys.readdir dir in
               Array.to_list files
               |> List.map (fun f -> 
                    let path = Filename.concat dir f in
                    let is_dir = try Sys.is_directory path with _ -> false in
                    `Assoc [("name", `String f); ("type", `String (if is_dir then "directory" else "file")); ("path", `String f)]
                  )
           in
           let tree = get_tree base in
           json_response ~status:`OK request reqd (`List tree))
           
  |> Http.Router.get "/api/v1/workspace/file" (fun request reqd ->
       match get_server_state_result () with
       | Error message -> json_response ~status:`Internal_server_error request reqd (json_error message)
       | Ok state ->
           let base = base_path_of_state state in
                      let uri = Uri.of_string request.target in
           match Uri.get_query_param uri "path" with
           | None -> json_response ~status:`Bad_request request reqd (json_error "Missing path parameter")
           | Some p ->
               let path = safe_path base p in
               if Sys.file_exists path && not (Sys.is_directory path) then
                                  try
                   let content = Fs_compat.load_file path in
                   let json = `Assoc [("ok", `Bool true); ("content", `String content)] in
                   json_response ~status:`OK request reqd json
                 with _ -> json_response ~status:`Internal_server_error request reqd (json_error "Failed to read file")
               else
                 json_response ~status:`Not_found request reqd (json_error "File not found"))
