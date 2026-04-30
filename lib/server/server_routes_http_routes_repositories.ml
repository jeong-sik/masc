open Server_auth
open Server_utils

module Http = Http_server_eio

let base_path_of_state state = state.Mcp_server.room_config.base_path

let json_error message =
  `Assoc [("ok", `Bool false); ("error", `String message)]

let json_response ~status req reqd json =
  Http.Response.json ~status ~request:req
    (Yojson.Safe.to_string json) reqd

let ok_json data =
  `Assoc [("ok", `Bool true); ("data", data)]

let repositories_prefix = "/api/v1/repositories/"
let sync_suffix = "/sync"

let extract_repo_id path =
  extract_path_param ~prefix:repositories_prefix path

let extract_repo_id_for_sync path =
  match extract_path_param ~prefix:repositories_prefix path with
  | None -> None
  | Some rest ->
      let suffix_len = String.length sync_suffix in
      let rest_len = String.length rest in
      if rest_len > suffix_len && String.sub rest (rest_len - suffix_len) suffix_len = sync_suffix then
        Some (String.sub rest 0 (rest_len - suffix_len))
      else
        None

let parse_repository_json body_str =
  match Yojson.Safe.from_string body_str with
  | json -> (
      match Repo_manager_types.repository_of_yojson json with
      | Ok repo -> Ok repo
      | Error msg -> Error ("invalid repository JSON: " ^ msg))
  | exception Yojson.Json_error msg ->
      Error ("invalid JSON body: " ^ msg)

let handle_list_repositories state req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.load_all ~base_path with
  | Error msg ->
      json_response ~status:`Internal_server_error req reqd (json_error msg)
  | Ok repos ->
      let json =
        ok_json (`List (List.map Repo_manager_types.repository_to_yojson repos))
      in
      Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd

let handle_get_repository state req reqd =
  let base_path = base_path_of_state state in
  let path = Http.Request.path req in
  match extract_repo_id path with
  | None ->
      json_response ~status:`Bad_request req reqd
        (json_error "repository id path parameter required")
  | Some id -> (
      match Repo_store.find ~base_path id with
      | Error msg ->
          json_response ~status:`Not_found req reqd (json_error msg)
      | Ok repo ->
          let json = ok_json (Repo_manager_types.repository_to_yojson repo) in
          Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd)

let handle_add_repository state _agent_name req reqd =
  let base_path = base_path_of_state state in
  Http.Request.read_body_async reqd (fun body_str ->
      match parse_repository_json body_str with
      | Error msg ->
          json_response ~status:`Bad_request req reqd (json_error msg)
      | Ok repo -> (
          match Repo_store.add ~base_path repo with
          | Error msg ->
              json_response ~status:`Bad_request req reqd (json_error msg)
          | Ok added_repo ->
              let json =
                ok_json (Repo_manager_types.repository_to_yojson added_repo)
              in
              Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd))

let handle_remove_repository state _agent_name req reqd =
  let base_path = base_path_of_state state in
  let path = Http.Request.path req in
  match extract_repo_id path with
  | None ->
      json_response ~status:`Bad_request req reqd
        (json_error "repository id path parameter required")
  | Some id -> (
      match Repo_store.remove ~base_path id with
      | Error msg ->
          json_response ~status:`Not_found req reqd (json_error msg)
      | Ok () ->
          let json = ok_json (`Assoc [("id", `String id)]) in
          Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd)

let handle_sync_repository state _agent_name req reqd =
  let base_path = base_path_of_state state in
  let path = Http.Request.path req in
  match extract_repo_id_for_sync path with
  | None ->
      json_response ~status:`Bad_request req reqd
        (json_error "repository id path parameter required")
  | Some id -> (
      match Repo_store.find ~base_path id with
      | Error msg ->
          json_response ~status:`Not_found req reqd (json_error msg)
      | Ok repo -> (
          match Credential_store.find ~base_path repo.credential_id with
          | Error msg ->
              json_response ~status:`Bad_request req reqd
                (json_error ("credential not found: " ^ msg))
          | Ok credential -> (
              match Repo_sync.sync_repository ~base_path repo credential with
              | Error msg ->
                  json_response ~status:`Internal_server_error req reqd
                    (json_error msg)
              | Ok () ->
                  let json = ok_json (`Assoc [("id", `String id)]) in
                  Http.Response.json ~request:req (Yojson.Safe.to_string json)
                    reqd)))

let add_routes router =
  router
  |> Http.Router.get "/api/v1/repositories" (fun request reqd ->
       with_public_read handle_list_repositories request reqd)
  |> Http.Router.prefix_get repositories_prefix (fun request reqd ->
       with_public_read handle_get_repository request reqd)
  |> Http.Router.post "/api/v1/repositories" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         handle_add_repository request reqd)
  |> Http.Router.add ~path:("PREFIX:" ^ repositories_prefix)
       ~methods:[`DELETE]
       ~handler:(fun request reqd ->
         with_token_permission_auth ~permission:Types.CanAdmin
           handle_remove_repository request reqd)
  |> Http.Router.prefix_post repositories_prefix (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         handle_sync_repository request reqd)
