open Server_auth
open Server_utils

module Http = Http_server_eio

let credential_json (c : Repo_manager_types.credential) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String c.id);
      ( "cred_type",
        `String
          (match c.cred_type with
           | Github -> "github"
           | Gitlab -> "gitlab"
           | Local -> "local") );
      ("username", `String c.username);
      ( "gh_config_dir",
        match c.gh_config_dir with Some s -> `String s | None -> `Null );
      ( "ssh_key_path",
        match c.ssh_key_path with Some s -> `String s | None -> `Null );
      ("gpg_key_id", match c.gpg_key_id with Some s -> `String s | None -> `Null);
    ]

let credential_of_json (json : Yojson.Safe.t) :
    (Repo_manager_types.credential, string) result =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
      let get_string key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Ok s
        | Some _ -> Error (Printf.sprintf "field %s must be a string" key)
        | None -> Error (Printf.sprintf "missing field %s" key)
      in
      let get_opt_string key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Ok (Some s)
        | Some `Null -> Ok None
        | Some _ -> Error (Printf.sprintf "field %s must be a string or null" key)
        | None -> Ok None
      in
      let* id = get_string "id" in
      let* cred_type_str = get_string "cred_type" in
      let* username = get_string "username" in
      let* gh_config_dir = get_opt_string "gh_config_dir" in
      let* ssh_key_path = get_opt_string "ssh_key_path" in
      let* gpg_key_id = get_opt_string "gpg_key_id" in
      let* cred_type =
        match cred_type_str with
        | "github" -> Ok Repo_manager_types.Github
        | "gitlab" -> Ok Gitlab
        | "local" -> Ok Local
        | _ -> Error (Printf.sprintf "unknown cred_type: %s" cred_type_str)
      in
      Ok { Repo_manager_types.id; cred_type; username; gh_config_dir; ssh_key_path; gpg_key_id }
  | _ -> Error "expected JSON object body"

let add_routes router =
  router
  |> Http.Router.get "/api/v1/credentials" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         match Credential_store.load_all ~base_path with
         | Error msg ->
             Http.Response.json ~status:`Internal_server_error ~request:req
               (Yojson.Safe.to_string
                  (`Assoc [ ("ok", `Bool false); ("error", `String msg) ]))
               reqd
         | Ok credentials ->
             let json = `Assoc [ ("credentials", `List (List.map credential_json credentials)) ] in
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json)
               reqd
       ) request reqd)
  |> Http.Router.prefix_get "/api/v1/credentials/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let path = Http.Request.path request in
         match extract_path_param ~prefix:"/api/v1/credentials/" path with
         | None | Some "" ->
             Http.Response.json ~status:`Bad_request ~request:req
               (Yojson.Safe.to_string
                  (`Assoc
                    [ ("ok", `Bool false); ("error", `String "missing credential id") ]))
               reqd
         | Some id -> (
             match Credential_store.find ~base_path id with
             | Error msg ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Yojson.Safe.to_string
                      (`Assoc [ ("ok", `Bool false); ("error", `String msg) ]))
                   reqd
             | Ok credential ->
                 Http.Response.json ~request:req
                   (Yojson.Safe.to_string (credential_json credential))
                   reqd)
       ) request reqd)
  |> Http.Router.post "/api/v1/credentials" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             let response status message =
               Http.Response.json ~status ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc [ ("ok", `Bool false); ("error", `String message) ]))
                 reqd
             in
             match Yojson.Safe.from_string body_str with
             | exception Yojson.Json_error msg ->
                 response `Bad_request ("invalid JSON body: " ^ msg)
             | json -> (
                 match credential_of_json json with
                 | Error msg -> response `Bad_request msg
                 | Ok credential ->
                     let base_path = state.Mcp_server.room_config.base_path in
                     match Credential_store.add ~base_path credential with
                     | Error msg -> response `Bad_request msg
                     | Ok cred ->
                         Http.Response.json ~request:req
                           (Yojson.Safe.to_string (credential_json cred))
                           reqd)))
         request reqd)
  |> Http.Router.add ~path:("PREFIX:/api/v1/credentials/")
       ~methods:[`DELETE]
       ~handler:(fun request reqd ->
         with_token_permission_auth ~permission:Types.CanAdmin
           (fun state _agent_name req reqd ->
             let base_path = state.Mcp_server.room_config.base_path in
             let path = Http.Request.path request in
             match extract_path_param ~prefix:"/api/v1/credentials/" path with
             | None | Some "" ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Yojson.Safe.to_string
                      (`Assoc
                        [ ("ok", `Bool false); ("error", `String "missing credential id") ]))
                   reqd
             | Some id -> (
                 match Credential_store.remove ~base_path id with
                 | Error msg ->
                     Http.Response.json ~status:`Bad_request ~request:req
                       (Yojson.Safe.to_string
                          (`Assoc [ ("ok", `Bool false); ("error", `String msg) ]))
                       reqd
                 | Ok () ->
                     Http.Response.json ~request:req
                       (Yojson.Safe.to_string (`Assoc [ ("ok", `Bool true) ]))
                       reqd)
           ) request reqd)
