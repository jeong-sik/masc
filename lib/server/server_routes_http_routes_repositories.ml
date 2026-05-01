open Server_auth
open Server_utils

module Http = Http_server_eio

let base_path_of_state state = state.Mcp_server.room_config.base_path

let json_error message =
  `Assoc [("ok", `Bool false); ("error", `String message)]

let json_response ~status req reqd json =
  Http.Response.json ~status ~request:req
    (Yojson.Safe.to_string json) reqd

let repositories_prefix = "/api/v1/repositories/"
let sync_suffix = "/sync"

let extract_repo_id path =
  extract_path_param ~prefix:repositories_prefix path

let path_parts rest =
  rest
  |> String.split_on_char '/'
  |> List.filter (fun part -> String.trim part <> "")

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

let timestamp_json value = `Intlit (Int64.to_string value)

let status_json = function
  | Repo_manager_types.Active -> ("active", None)
  | Paused -> ("paused", None)
  | Cloning -> ("cloning", None)
  | Error msg -> ("error", Some msg)

let repository_json (repo : Repo_manager_types.repository) =
  let status, error = status_json repo.status in
  let fields =
    [
      ("id", `String repo.id);
      ("name", `String repo.name);
      ("url", `String repo.url);
      ("local_path", `String repo.local_path);
      ("default_branch", `String repo.default_branch);
      ("credential_id", `String repo.credential_id);
      ("keepers", `List (List.map (fun s -> `String s) repo.keepers));
      ("status", `String status);
      ("auto_sync", `Bool repo.auto_sync);
      ("sync_interval", `Int repo.sync_interval);
      ("created_at", timestamp_json repo.created_at);
      ("updated_at", timestamp_json repo.updated_at);
    ]
  in
  let fields =
    match error with
    | None -> fields
    | Some msg -> ("error_message", `String msg) :: fields
  in
  `Assoc fields

let branch_json ~default_branch name =
  let remote_prefix = "remotes/" in
  let is_remote =
    String.starts_with ~prefix:remote_prefix name
    || String.starts_with ~prefix:"origin/" name
  in
  let short_name =
    if String.starts_with ~prefix:remote_prefix name then
      String.sub name (String.length remote_prefix)
        (String.length name - String.length remote_prefix)
    else name
  in
  let default_names = [default_branch; "origin/" ^ default_branch] in
  `Assoc
    [
      ("name", `String short_name);
      ("is_default", `Bool (List.exists (String.equal short_name) default_names));
      ("is_remote", `Bool is_remote);
      ("last_commit_at", `Null);
    ]

let slug_of_repo_name name =
  let raw = String.lowercase_ascii (String.trim name) in
  let buf = Buffer.create (String.length raw) in
  String.iter
    (fun c ->
      let keep =
        (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9')
        || c = '-'
        || c = '_'
      in
      Buffer.add_char buf (if keep then c else '-'))
    raw;
  let slug = Buffer.contents buf |> String.trim in
  if slug = "" then None else Some slug

let repo_name_from_url url =
  let trimmed = String.trim url in
  let last =
    match List.rev (String.split_on_char '/' trimmed) with
    | part :: _ -> part
    | [] -> trimmed
  in
  if Filename.check_suffix last ".git" then
    String.sub last 0 (String.length last - 4)
  else last

let get_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> Ok (Some s)
  | Some `Null | None -> Ok None
  | Some _ -> Error (Printf.sprintf "field %s must be a string" key)

let get_bool_field fields key default =
  match List.assoc_opt key fields with
  | Some (`Bool b) -> Ok b
  | None -> Ok default
  | Some _ -> Error (Printf.sprintf "field %s must be a boolean" key)

let get_int_field fields key default =
  match List.assoc_opt key fields with
  | Some (`Int i) -> Ok i
  | Some (`Intlit s) -> (
      match int_of_string_opt s with
      | Some i -> Ok i
      | None -> Error (Printf.sprintf "field %s must be an integer" key))
  | None -> Ok default
  | Some _ -> Error (Printf.sprintf "field %s must be an integer" key)

let get_string_list_field fields key default =
  match List.assoc_opt key fields with
  | None -> Ok default
  | Some (`List items) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | `String s :: rest -> loop (s :: acc) rest
        | _ -> Error (Printf.sprintf "field %s must be an array of strings" key)
      in
      loop [] items
  | Some _ -> Error (Printf.sprintf "field %s must be an array of strings" key)

let parse_repository_json body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let* raw_name = get_string_field fields "name" in
      let* raw_url = get_string_field fields "url" in
      let url = Option.value ~default:"" raw_url |> String.trim in
      if url = "" then Error "field url is required"
      else
        let inferred_name =
          match raw_name with
          | Some name when String.trim name <> "" -> String.trim name
          | _ -> repo_name_from_url url
        in
        let* raw_id = get_string_field fields "id" in
        let id_source =
          match raw_id with
          | Some id when String.trim id <> "" -> String.trim id
          | _ -> inferred_name
        in
        (match slug_of_repo_name id_source with
        | None -> Error "repository id could not be inferred"
        | Some id ->
            let* raw_local_path = get_string_field fields "local_path" in
            let* raw_default_branch =
              get_string_field fields "default_branch"
            in
            let* raw_credential_id = get_string_field fields "credential_id" in
            let* keepers = get_string_list_field fields "keepers" [] in
            let* auto_sync = get_bool_field fields "auto_sync" false in
            let* sync_interval = get_int_field fields "sync_interval" 300 in
            Ok
              {
                Repo_manager_types.id;
                name = inferred_name;
                url;
                local_path =
                  Option.value ~default:(Filename.concat ".masc/repos" id)
                    raw_local_path;
                default_branch = Option.value ~default:"main" raw_default_branch;
                credential_id = Option.value ~default:"default" raw_credential_id;
                keepers;
                status = Active;
                auto_sync;
                sync_interval;
                created_at = Int64.zero;
                updated_at = Int64.zero;
              })
  | _ -> Error "invalid repository JSON: expected object"
  | exception Yojson.Json_error msg ->
      Error ("invalid JSON body: " ^ msg)

let handle_list_repositories state req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.load_all ~base_path with
  | Error msg ->
      json_response ~status:`Internal_server_error req reqd (json_error msg)
  | Ok repos ->
      let json =
        `Assoc
          [
            ("repositories", `List (List.map repository_json repos));
            ("total", `Int (List.length repos));
          ]
      in
      Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd

let handle_get_repository state id req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.find ~base_path id with
  | Error msg -> json_response ~status:`Not_found req reqd (json_error msg)
  | Ok repo ->
      Http.Response.json ~request:req
        (Yojson.Safe.to_string (repository_json repo))
        reqd

let handle_list_branches state id req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.find ~base_path id with
  | Error msg -> json_response ~status:`Not_found req reqd (json_error msg)
  | Ok repo -> (
      match Repo_store.list_branches ~base_path id with
      | Error msg ->
          json_response ~status:`Internal_server_error req reqd (json_error msg)
      | Ok branches ->
          let json =
            `Assoc
              [
                ("repository_id", `String id);
                ( "branches",
                  `List
                    (List.map (branch_json ~default_branch:repo.default_branch)
                       branches) );
              ]
          in
          Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd)

let handle_get_repository_path state req reqd =
  match extract_repo_id (Http.Request.path req) with
  | None | Some "" ->
      json_response ~status:`Bad_request req reqd
        (json_error "repository id path parameter required")
  | Some rest -> (
      match path_parts rest with
      | [id] -> handle_get_repository state id req reqd
      | [id; "branches"] -> handle_list_branches state id req reqd
      | _ ->
          json_response ~status:`Not_found req reqd
            (json_error "unknown repository endpoint"))

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
              let json = repository_json added_repo in
              Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd))

let handle_remove_repository state _agent_name req reqd =
  let base_path = base_path_of_state state in
  let path = Http.Request.path req in
  match extract_repo_id path with
  | None | Some "" ->
      json_response ~status:`Bad_request req reqd
        (json_error "repository id path parameter required")
  | Some rest -> (
      match path_parts rest with
      | [id] -> (
      match Repo_store.remove ~base_path id with
      | Error msg ->
          json_response ~status:`Not_found req reqd (json_error msg)
      | Ok () ->
          let json = `Assoc [("id", `String id); ("removed", `Bool true)] in
          Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd)
      | _ ->
          json_response ~status:`Bad_request req reqd
            (json_error "DELETE expects /api/v1/repositories/:id"))

let handle_update_repository state _agent_name req reqd =
  let base_path = base_path_of_state state in
  let path = Http.Request.path req in
  match extract_repo_id path with
  | None | Some "" ->
      json_response ~status:`Bad_request req reqd
        (json_error "repository id path parameter required")
  | Some rest -> (
      match path_parts rest with
      | [id] -> (
          Http.Request.read_body_async reqd (fun body_str ->
              match parse_repository_json body_str with
              | Error msg ->
                  json_response ~status:`Bad_request req reqd (json_error msg)
              | Ok repo -> (
                  (* Check existence first so we can return 404 vs 500 *)
                  match Repo_store.find ~base_path id with
                  | Error _ ->
                      json_response ~status:`Not_found req reqd
                        (json_error (Printf.sprintf "Repository not found: %s" id))
                  | Ok _ -> (
                      let repo = { repo with id } in
                      match Repo_store.update ~base_path id repo with
                      | Error msg ->
                          json_response ~status:`Internal_server_error req reqd
                            (json_error msg)
                      | Ok persisted ->
                          Http.Response.json ~request:req
                            (Yojson.Safe.to_string (repository_json persisted))
                            reqd))))
      | _ ->
          json_response ~status:`Not_found req reqd
            (json_error "unknown repository endpoint"))

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
                  let branches =
                    match Repo_store.list_branches ~base_path id with
                    | Ok branches ->
                        `List
                          (List.map
                             (branch_json ~default_branch:repo.default_branch)
                             branches)
                    | Error _ -> `List []
                  in
                  let json =
                    `Assoc
                      [
                        ("id", `String id);
                        ("status", `String "active");
                        ("branches", branches);
                      ]
                  in
                  Http.Response.json ~request:req (Yojson.Safe.to_string json)
                    reqd)))

let handle_discover_repositories state _agent_name req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.discover_repositories ~base_path with
  | Error msg ->
      json_response ~status:`Internal_server_error req reqd (json_error msg)
  | Ok repos ->
      let json =
        `Assoc
          [
            ("repositories", `List (List.map repository_json repos));
            ("total", `Int (List.length repos));
            ("discovered", `Bool true);
          ]
      in
      Http.Response.json ~request:req (Yojson.Safe.to_string json) reqd

let add_routes router =
  router
  |> Http.Router.get "/api/v1/repositories" (fun request reqd ->
       with_public_read handle_list_repositories request reqd)
  |> Http.Router.prefix_get repositories_prefix (fun request reqd ->
       with_public_read handle_get_repository_path request reqd)
  |> Http.Router.post "/api/v1/repositories" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         handle_add_repository request reqd)
  |> Http.Router.post "/api/v1/repositories/discover" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         handle_discover_repositories request reqd)
  |> Http.Router.add ~path:("PREFIX:" ^ repositories_prefix)
       ~methods:[`DELETE]
       ~handler:(fun request reqd ->
         with_token_permission_auth ~permission:Types.CanAdmin
           handle_remove_repository request reqd)
  |> Http.Router.add ~path:("PREFIX:" ^ repositories_prefix)
       ~methods:[`PUT]
       ~handler:(fun request reqd ->
         with_token_permission_auth ~permission:Types.CanAdmin
           handle_update_repository request reqd)
  |> Http.Router.prefix_post repositories_prefix (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         handle_sync_repository request reqd)
