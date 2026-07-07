open Server_auth
open Server_utils

module Http = Http_server_eio

let base_path_of_state state = (Mcp_server.workspace_config state).base_path

let json_error message =
  `Assoc [("ok", `Bool false); ("error", `String message)]

let json_response ~status req reqd json =
  Http.Response.json_value ~status ~request:req json reqd

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

let git_status_json ~base_path (repo : Repo_manager_types.repository) =
  let abs_local_path = Repo_store.local_path ~base_path repo in
  let repo_for_git = { repo with local_path = abs_local_path } in
  match Repo_git.status_summary ~repository:repo_for_git with
  | Ok summary ->
      `Assoc
        [
          ("state", `String "available");
          ("source", `String "git-status-porcelain-v1");
          ("dirty", `Bool (summary.changed_files > 0));
          ("changed_files", `Int summary.changed_files);
          ("staged_files", `Int summary.staged_files);
          ("unstaged_files", `Int summary.unstaged_files);
          ("untracked_files", `Int summary.untracked_files);
          ("conflicted_files", `Int summary.conflicted_files);
        ]
  | Error msg ->
      `Assoc
        [
          ("state", `String "unavailable");
          ("source", `String "git-status-porcelain-v1");
          ("error", `String msg);
        ]

(* Currency of the managed clone versus its fetched remote default branch.
   [behind > 0] means readers of this repository (IDE workspace tree, file,
   diff, blame) are looking at an out-of-date working tree — surfaced here so
   the dashboard can render staleness instead of implying "no changes". *)
let sync_currency_json ~base_path (repo : Repo_manager_types.repository) =
  let abs_local_path = Repo_store.local_path ~base_path repo in
  let repo_for_git = { repo with local_path = abs_local_path } in
  let target_ref = "origin/" ^ repo.default_branch in
  match Repo_git.ahead_behind ~repository:repo_for_git ~target_ref with
  | Ok (behind, ahead) ->
      `Assoc
        [
          ("state", `String "available");
          ("target_ref", `String target_ref);
          ("behind", `Int behind);
          ("ahead", `Int ahead);
        ]
  | Error msg ->
      `Assoc
        [
          ("state", `String "unavailable");
          ("target_ref", `String target_ref);
          ("error", `String msg);
        ]

let repository_json ~base_path (repo : Repo_manager_types.repository) =
  let status, error = status_json repo.status in
  let fields =
    [
      ("id", `String repo.id);
      ("name", `String repo.name);
      ("url", `String repo.url);
      ("local_path", `String repo.local_path);
      ("aliases", `List (List.map (fun s -> `String s) repo.aliases));
      ("default_branch", `String repo.default_branch);
      ("keepers", `List (List.map (fun s -> `String s) repo.keepers));
      ("status", `String status);
      ("auto_sync", `Bool repo.auto_sync);
      ("sync_interval", `Int repo.sync_interval);
      ("created_at", timestamp_json repo.created_at);
      ("updated_at", timestamp_json repo.updated_at);
      ("git_status", git_status_json ~base_path repo);
      ("sync_currency", sync_currency_json ~base_path repo);
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
          | Some name ->
              let trimmed = String.trim name in
              if trimmed <> "" then trimmed else repo_name_from_url url
          | None -> repo_name_from_url url
        in
        let* raw_id = get_string_field fields "id" in
        let id_source =
          match raw_id with
          | Some id ->
              let trimmed = String.trim id in
              if trimmed <> "" then trimmed else inferred_name
          | None -> inferred_name
        in
        (match slug_of_repo_name id_source with
        | None -> Error "repository id could not be inferred"
        | Some id ->
            let* raw_local_path = get_string_field fields "local_path" in
            let* raw_default_branch =
              get_string_field fields "default_branch"
            in
            let* aliases = get_string_list_field fields "aliases" [] in
            let* keepers = get_string_list_field fields "keepers" [] in
            let* auto_sync = get_bool_field fields "auto_sync" false in
            let* sync_interval = get_int_field fields "sync_interval" 300 in
            Ok
              {
                Repo_manager_types.id;
                name = inferred_name;
                url;
                local_path =
                  (* RFC-0121 §6 deferred: same TOML-default cwd-relative
                     semantics as Repo_store.default_local_path. *)
                  Option.value ~default:(Filename.concat ".masc/repos" id)
                    raw_local_path;
                aliases;
                default_branch = Option.value ~default:"main" raw_default_branch;
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
            ("repositories", `List (List.map (repository_json ~base_path) repos));
            ("total", `Int (List.length repos));
          ]
      in
      Http.Response.json_value ~request:req json reqd

let handle_get_repository state id req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.find ~base_path id with
  | Error msg -> json_response ~status:`Not_found req reqd (json_error msg)
  | Ok repo ->
      Http.Response.json_value ~request:req (repository_json ~base_path repo) reqd

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
          Http.Response.json_value ~request:req json reqd)

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
              let json = repository_json ~base_path added_repo in
              Http.Response.json_value ~request:req json reqd))

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
          Http.Response.json_value ~request:req json reqd)
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
                          Http.Response.json_value ~request:req
                            (repository_json ~base_path persisted) reqd))))
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
          match Repo_sync.sync_repository ~base_path repo with
          | Error msg ->
              json_response ~status:`Internal_server_error req reqd
                (json_error msg)
          | Ok outcome ->
              let advance_fields =
                match outcome with
                | Repo_sync.Advanced { behind } -> [ ("behind", `Int behind) ]
                | Repo_sync.Already_current -> []
                | Repo_sync.Skipped_dirty { staged; unstaged; conflicted } ->
                    [
                      ("staged", `Int staged);
                      ("unstaged", `Int unstaged);
                      ("conflicted", `Int conflicted);
                    ]
                | Repo_sync.Skipped_not_on_default_branch { current } ->
                    [ ("current_branch", `String current) ]
                | Repo_sync.Fast_forward_refused { behind; reason } ->
                    [ ("behind", `Int behind); ("reason", `String reason) ]
                | Repo_sync.Advance_inspect_failed { reason } ->
                    [ ("reason", `String reason) ]
              in
              let advance_json =
                `Assoc
                  (("state", `String (Repo_sync.advance_outcome_label outcome))
                   :: advance_fields)
              in
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
                    ("advance", advance_json);
                    ("branches", branches);
                  ]
              in
              Http.Response.json_value ~request:req json reqd))

let handle_discover_repositories state _agent_name req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.register_discovered ~base_path with
  | Error msg ->
      json_response ~status:`Internal_server_error req reqd (json_error msg)
  | Ok repos ->
      let json =
        `Assoc
          [
            ("repositories", `List (List.map (repository_json ~base_path) repos));
            ("total", `Int (List.length repos));
            ("discovered", `Bool true);
            ("registered", `Bool true);
          ]
      in
      Http.Response.json_value ~request:req json reqd

let add_routes router =
  router
  |> Http.Router.get "/api/v1/repositories" (fun request reqd ->
       with_public_read handle_list_repositories request reqd)
  |> Http.Router.prefix_get repositories_prefix (fun request reqd ->
       with_public_read handle_get_repository_path request reqd)
  |> Http.Router.post "/api/v1/repositories" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         handle_add_repository request reqd)
  |> Http.Router.post "/api/v1/repositories/discover" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         handle_discover_repositories request reqd)
  |> Http.Router.prefix_delete repositories_prefix (fun request reqd ->
         with_token_permission_auth ~permission:Masc_domain.CanAdmin
           handle_remove_repository request reqd)
  |> Http.Router.prefix_put repositories_prefix (fun request reqd ->
         with_token_permission_auth ~permission:Masc_domain.CanAdmin
           handle_update_repository request reqd)
  |> Http.Router.prefix_post repositories_prefix (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         handle_sync_repository request reqd)
