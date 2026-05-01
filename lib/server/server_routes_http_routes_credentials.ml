open Server_auth
open Server_utils

module Http = Http_server_eio

(* RFC-0019 §4.2: surface credential_state in the API so dashboard
   clients can render Materialised / Unmaterialised / Stale labels.
   token_sha256_prefix is included for operator-side F-1 diagnostics
   but never the full token. *)
let credential_state_json (s : Repo_manager_types.credential_state)
    : Yojson.Safe.t =
  match s with
  | Unmaterialized -> `Assoc [ ("kind", `String "Unmaterialized") ]
  | Materialized { last_verified_at } ->
      `Assoc
        [ ("kind", `String "Materialized");
          ("last_verified_at_unix_ms",
           `Intlit (Int64.to_string last_verified_at)) ]
  | Stale { reason } ->
      `Assoc
        [ ("kind", `String "Stale"); ("reason", `String reason) ]

let credential_json (c : Repo_manager_types.credential) : Yojson.Safe.t =
  let typ =
    match c.cred_type with
    | Github -> "github"
    | Gitlab -> "gitlab"
    | Local -> "local"
  in
  `Assoc
    [
      ("id", `String c.id);
      ("name", `String c.username);
      ("type", `String typ);
      ("cred_type", `String typ);
      ("username", `String c.username);
      ( "gh_config_dir",
        match c.gh_config_dir with Some s -> `String s | None -> `Null );
      ( "ssh_key_path",
        match c.ssh_key_path with Some s -> `String s | None -> `Null );
      ("gpg_key_id", match c.gpg_key_id with Some s -> `String s | None -> `Null);
      ("state", credential_state_json c.state);
      ( "token_sha256_prefix",
        match c.token_sha256_prefix with
        | Some s -> `String s
        | None -> `Null );
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
      let get_string_alias keys =
        let rec loop = function
          | [] -> Error (Printf.sprintf "missing field %s" (String.concat "/" keys))
          | key :: rest -> (
              match List.assoc_opt key fields with
              | Some (`String s) -> Ok s
              | Some _ -> Error (Printf.sprintf "field %s must be a string" key)
              | None -> loop rest)
        in
        loop keys
      in
      let get_opt_string key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Ok (Some s)
        | Some `Null -> Ok None
        | Some _ -> Error (Printf.sprintf "field %s must be a string or null" key)
        | None -> Ok None
      in
      let* id = get_string "id" in
      let* cred_type_str = get_string_alias ["cred_type"; "type"] in
      let* username = get_string_alias ["username"; "name"] in
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
      (* RFC-0019 PR-B §4.4: state is stamped by
         [Credential_materializer.ensure] inside [Credential_store.add];
         clients posting fresh credentials surface as [Unmaterialized]
         until the materialiser runs.  token_sha256_prefix populated by
         the F-1 gate (PR-C). *)
      Ok
        {
          Repo_manager_types.id;
          cred_type;
          username;
          gh_config_dir;
          ssh_key_path;
          gpg_key_id;
          state = Unmaterialized;
          token_sha256_prefix = None;
        }
  | _ -> Error "expected JSON object body"

let default_github_gh_config_dir ~base_path ~credential_id =
  Filename.concat
    (Filename.concat base_path ".masc/github-identities")
    (Filename.concat credential_id "gh")

let apply_base_path_defaults ~base_path
    (credential : Repo_manager_types.credential) =
  match credential.cred_type, credential.gh_config_dir with
  | Repo_manager_types.Github, None ->
      { credential with
        gh_config_dir =
          Some
            (default_github_gh_config_dir ~base_path
               ~credential_id:credential.id)
      }
  | _ -> credential

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
             let credentials =
               if List.exists
                    (fun (c : Repo_manager_types.credential) ->
                      String.equal c.id Credential_store.default_credential.id)
                    credentials
               then credentials
               else Credential_store.default_credential :: credentials
             in
             let json =
               `Assoc
                 [
                   ("credentials", `List (List.map credential_json credentials));
                   ("total", `Int (List.length credentials));
                 ]
             in
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
                 (* RFC-0019 PR-B Slice 2: oauth_method controls the
                    provisioning flow.  Default "web" preserves the
                    existing behaviour (record only, operator runs
                    `gh auth login` manually).  "with_token" runs
                    `gh auth login --with-token` server-side.  The token
                    is consumed at most once and never logged. *)
                 let oauth_method =
                   match json with
                   | `Assoc fields -> (
                       match List.assoc_opt "oauth_method" fields with
                       | Some (`String s) -> s
                       | _ -> "web")
                   | _ -> "web"
                 in
                 let token_opt =
                   match json with
                   | `Assoc fields -> (
                       match List.assoc_opt "token" fields with
                       | Some (`String s) -> Some s
                       | _ -> None)
                   | _ -> None
                 in
                 match credential_of_json json with
                 | Error msg -> response `Bad_request msg
                 | Ok credential ->
                     let base_path = state.Mcp_server.room_config.base_path in
                     (* Sanity-check the credential id so it can be
                        embedded in a path safely (used both for
                        server-derived gh_config_dir and for any
                        downstream filesystem reference). *)
                     let id_safe =
                       (not (String.contains credential.id '/'))
                       && not (String.contains credential.id '\\')
                       && credential.id <> ".."
                       && credential.id <> "."
                       && String.length credential.id > 0
                     in
                     if not id_safe then
                       response `Bad_request
                         "credential id must be a non-empty filename \
                          fragment without slashes or directory traversal"
                     else
                       (* GitHub credentials are rooted under the active
                          server base_path when the operator leaves
                          GH_CONFIG_DIR blank.  This keeps both web and
                          with-token login flows on the same
                          MASC-owned bundle layout. *)
                       let credential =
                         apply_base_path_defaults ~base_path credential
                       in
                       match oauth_method with
                       | "web" -> (
                           match Credential_store.add ~base_path credential with
                           | Error msg -> response `Bad_request msg
                           | Ok cred ->
                               Http.Response.json ~request:req
                                 (Yojson.Safe.to_string (credential_json cred))
                                 reqd)
                       | "with_token" -> (
                           match token_opt with
                           | None ->
                               response `Bad_request
                                 "with_token oauth_method requires a \
                                  \"token\" field"
                           | Some token -> (
                               match credential.gh_config_dir with
                               | None ->
                                   response `Bad_request
                                     "with_token oauth_method requires \
                                      gh_config_dir or a server-derived \
                                      default"
                               | Some dir -> (
                                   match
                                     Credential_materializer
                                     .provision_via_with_token
                                       ~credential_id:credential.id
                                       ~identity_label:credential.username
                                       ~gh_config_dir:dir ~token ()
                                   with
                                   | Error msg -> response `Bad_request msg
                                   | Ok _state -> (
                                       (* RFC-0019 PR-C F-1 gate
                                          (permissive): emit the
                                          gate_warned counter when the
                                          freshly-provisioned bundle's
                                          token fingerprint matches the
                                          operator ambient `gh auth
                                          token`.  Operator can trace
                                          credentials that share their
                                          PAT via Prometheus before
                                          PR-D ramps the gate to strict.
                                          Never blocks materialisation. *)
                                       (match
                                          Credential_materializer
                                          .f1_gate_check
                                            ~credential_id:credential.id
                                            ~gh_config_dir:dir
                                        with
                                        | Credential_materializer
                                          .F1_shared_with_operator ->
                                            Prometheus.inc_counter
                                              "keeper_credential_provider_gate_warned_total"
                                              ~labels:
                                                [ ("credential_id",
                                                   credential.id);
                                                  ("scope",
                                                   "shared_with_operator") ]
                                              ()
                                        | F1_distinct | F1_skipped _ ->
                                            ());
                                       match
                                         Credential_store.add
                                           ~base_path credential
                                       with
                                       | Error msg -> response `Bad_request msg
                                       | Ok cred ->
                                           Http.Response.json ~request:req
                                             (Yojson.Safe.to_string
                                                (credential_json cred))
                                             reqd))))
                       | other ->
                           response `Bad_request
                             (Printf.sprintf
                                "unknown oauth_method: %S; expected \
                                 \"web\" or \"with_token\""
                                other))))
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
