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

let extract_repo_id_for_sync path =
  match extract_path_param ~prefix:repositories_prefix path with
  | None -> None
  | Some rest ->
      let suffix_len = String.length sync_suffix in
      let rest_len = String.length rest in
      if rest_len > suffix_len && String.ends_with ~suffix:sync_suffix rest then
        Some (String.sub rest 0 (rest_len - suffix_len))
      else
        None

let timestamp_json value = `Intlit (Int64.to_string value)

let status_json status =
  ( Repo_manager_types.status_wire_name status
  , Repo_manager_types.status_error_message status )

let git_status_json ~base_path (repo : Repo_manager_types.repository) =
  let abs_local_path = Repo_store.local_path ~base_path repo in
  let repo_for_git = { repo with local_path = abs_local_path } in
  match Repo_git.status_summary ~repository:repo_for_git () with
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
  match Repo_git.ahead_behind ~repository:repo_for_git ~target_ref () with
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
      (* The server is the only slug mint — clients carry
         this value into co-view context and scope queries instead of
         re-deriving it from the url. [`Null] when the url cannot
         canonicalize (blank or local-path remote). *)
      ( "codebase",
        match Agent_observation.canonical_url_of_remote repo.url with
        | Some slug -> `String slug
        | None -> `Null );
      ("local_path", `String repo.local_path);
      (* [local_path] is the persisted declaration and may be relative.  The
         server is the only process that knows which base path resolves it;
         clients must not repeat that resolution against their own cwd. *)
      ( "resolved_local_path"
      , `String (Repo_store.local_path ~base_path repo) );
      ("aliases", `List (List.map (fun s -> `String s) repo.aliases));
      ("default_branch", `String repo.default_branch);
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

(* The same repository, plus what only git can answer: whether the working tree
   is dirty and how far it has drifted from its remote. Each of those is a
   subprocess, so this is the shape a caller asks for one repository at a time —
   never the shape a list is built from. Listing five registered repositories
   used to run ten git processes and take 4.0-5.5 s to return 2.8 KB, on every
   request, uncached; the dashboard needs this state for the one repository in
   its status bar. *)
let repository_observation_json ~base_path (repo : Repo_manager_types.repository) =
  let git_fields =
    [ ("git_status", git_status_json ~base_path repo)
    ; ("sync_currency", sync_currency_json ~base_path repo)
    ]
  in
  match repository_json ~base_path repo with
  | `Assoc fields -> `Assoc (fields @ git_fields)
  | other -> other

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
      let open Result.Syntax in
      let* raw_name = get_string_field fields "name" in
      let* raw_url = get_string_field fields "url" in
      let url = Option.value ~default:"" raw_url |> String.trim in
      if url = "" then Error "field url is required"
      else
        let* () = Repo_git.validate_argument ~field:"url" url in
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
            let default_branch = Option.value ~default:"main" raw_default_branch in
            let* () =
              Repo_git.validate_argument ~field:"default_branch" default_branch
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
                  (* New repository requests may omit the managed checkout
                     location; the HTTP constructor owns that choice. The
                     default is base-path-relative because Repo_store.local_path
                     concats it onto the base path. *)
                  Option.value
                    ~default:(Config_dir_resolver.repos_relative_path ~id)
                    raw_local_path;
                aliases;
                default_branch;
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
      Http.Response.json_value ~request:req
        (repository_observation_json ~base_path repo) reqd

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

let handle_list_repository_changes state id req reqd =
  let base_path = base_path_of_state state in
  match Repo_store.find ~base_path id with
  | Error msg -> json_response ~status:`Not_found req reqd (json_error msg)
  | Ok repo ->
      let local_path = Repo_store.local_path ~base_path repo in
      (match Repo_git.status_snapshot_at ~local_path () with
       | Error msg ->
           json_response ~status:`Internal_server_error req reqd
             (json_error msg)
       | Ok (changes, branch) ->
           Http.Response.json_value ~request:req
             (Server_git_status_json.snapshot
                ~scope:
                  (`Assoc
                     [ ("kind", `String "repository")
                     ; ("repository_id", `String id)
                     ])
                ~branch ~changes)
             reqd)

let handle_get_repository_path state req reqd =
  match extract_repo_id (Http.Request.path req) with
  | None | Some "" ->
      json_response ~status:`Bad_request req reqd
        (json_error "repository id path parameter required")
  | Some rest -> (
      match path_parts rest with
      | [id] -> handle_get_repository state id req reqd
      | [id; "branches"] -> handle_list_branches state id req reqd
      | [id; "changes"] -> handle_list_repository_changes state id req reqd
      | _ ->
          json_response ~status:`Not_found req reqd
            (json_error "unknown repository endpoint"))

let path_is_within ~root candidate =
  String.equal candidate root
  || String.starts_with
       ~prefix:(if String.ends_with ~suffix:"/" root then root else root ^ "/")
       candidate

let rec has_escaping_or_dangling_symlink ~real_base path =
  if String.equal path real_base || String.equal (Filename.dirname path) path
  then false
  else
    has_escaping_or_dangling_symlink ~real_base (Filename.dirname path)
    ||
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_LNK; _ } ->
      (match Unix.realpath path with
       | resolved -> not (path_is_within ~root:real_base resolved)
       | exception Unix.Unix_error _ -> true)
    | { Unix.st_kind =
          (Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK)
      ; _
      } -> false
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
    | exception Unix.Unix_error _ -> true

let validate_http_local_path ~base_path raw_local_path =
  let trimmed = String.trim raw_local_path in
  if trimmed = "" then
    Error "field local_path must not be blank"
  else if String.contains trimmed '\000' then
    Error "field local_path contains an invalid NUL byte"
  else if
    List.exists
      (fun seg -> String.equal seg "..")
      (String.split_on_char '/' trimmed)
  then
    Error "field local_path must not contain parent-directory traversal"
  else
    let real_base = Fs_compat.realpath_lenient base_path in
    let candidate =
      if Filename.is_relative trimmed then Filename.concat real_base trimmed
      else trimmed
    in
    let resolved = Fs_compat.realpath_lenient candidate in
    if not (path_is_within ~root:real_base resolved)
       || has_escaping_or_dangling_symlink ~real_base candidate
    then
      Error "field local_path must resolve within the workspace base_path"
    else
      Ok trimmed

let parse_updatable_status = function
  | "active" -> Ok Repo_manager_types.Active
  | "paused" -> Ok Repo_manager_types.Paused
  | other ->
    Error
      (Printf.sprintf
         "field status must be \"active\" or \"paused\", got %S"
         other)

let apply_repository_update_json ~base_path ~(existing : Repo_manager_types.repository) body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields ->
      let open Result.Syntax in
      let* raw_name = get_string_field fields "name" in
      let* raw_url = get_string_field fields "url" in
      let* raw_local_path = get_string_field fields "local_path" in
      let* raw_default_branch = get_string_field fields "default_branch" in
      let* raw_status = get_string_field fields "status" in
      let* aliases = get_string_list_field fields "aliases" existing.aliases in
      let* keepers = get_string_list_field fields "keepers" existing.keepers in
      let* auto_sync = get_bool_field fields "auto_sync" existing.auto_sync in
      let* sync_interval =
        get_int_field fields "sync_interval" existing.sync_interval
      in
      let* url =
        match raw_url with
        | None -> Ok existing.url
        | Some u ->
          let t = String.trim u in
          if t = "" then Error "field url must not be blank" else Ok t
      in
      let name =
        match raw_name with
        | None -> existing.name
        | Some n ->
          let t = String.trim n in
          if t = "" then existing.name else t
      in
      let* local_path =
        match raw_local_path with
        | None -> Ok existing.local_path
        | Some p -> validate_http_local_path ~base_path p
      in
      let default_branch =
        match raw_default_branch with
        | None -> existing.default_branch
        | Some b ->
          let t = String.trim b in
          if t = "" then existing.default_branch else t
      in
      let* () = Repo_git.validate_argument ~field:"url" url in
      let* () = Repo_git.validate_argument ~field:"default_branch" default_branch in
      let* status =
        match raw_status with
        | None -> Ok existing.status
        | Some s -> parse_updatable_status (String.lowercase_ascii (String.trim s))
      in
      Ok
        {
          existing with
          name;
          url;
          local_path;
          aliases;
          default_branch;
          keepers;
          status;
          auto_sync;
          sync_interval;
        }
  | _ -> Error "invalid repository JSON: expected object"
  | exception Yojson.Json_error msg ->
      Error ("invalid JSON body: " ^ msg)

let handle_add_repository state _agent_name req reqd =
  let base_path = base_path_of_state state in
  Http.Request.read_body_async reqd (fun body_str ->
      match parse_repository_json body_str with
      | Error msg ->
          json_response ~status:`Bad_request req reqd (json_error msg)
      | Ok repo -> (
          match validate_http_local_path ~base_path repo.local_path with
          | Error msg ->
              json_response ~status:`Bad_request req reqd (json_error msg)
          | Ok safe_local_path -> (
              match Repo_store.add ~base_path { repo with local_path = safe_local_path } with
              | Error msg ->
                  json_response ~status:`Bad_request req reqd (json_error msg)
              | Ok added_repo ->
                  let json = repository_json ~base_path added_repo in
                  Http.Response.json_value ~request:req json reqd)))

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
              (* Check existence first so we can return 404 and merge partial updates *)
              match Repo_store.find ~base_path id with
              | Error _ ->
                  json_response ~status:`Not_found req reqd
                    (json_error (Printf.sprintf "Repository not found: %s" id))
              | Ok existing -> (
                  match apply_repository_update_json ~base_path ~existing body_str with
                  | Error msg ->
                      json_response ~status:`Bad_request req reqd (json_error msg)
                  | Ok updated_repo -> (
                      match Repo_store.update ~base_path id updated_repo with
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
  |> Server_route.get Server_route.Public_read "/api/v1/repositories" handle_list_repositories
  (* Exact, so it is found before the [/:id] prefix route below. *)
  |> Server_route.get Server_route.Public_read "/api/v1/repositories/pulls" (fun _state req reqd ->
           Http.Response.json_value ~request:req
             (Repository_pulls.snapshot_to_yojson
                (Repository_pulls.current ()))
             reqd)
  |> Server_route.prefix_get Server_route.Public_read repositories_prefix handle_get_repository_path
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/repositories" handle_add_repository
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/repositories/discover" handle_discover_repositories
  |> Server_route.prefix_delete (Server_route.Token_permission Masc_domain.CanAdmin) repositories_prefix handle_remove_repository
  |> Server_route.prefix_put (Server_route.Token_permission Masc_domain.CanAdmin) repositories_prefix handle_update_repository
  |> Server_route.prefix_post (Server_route.Token_permission Masc_domain.CanAdmin) repositories_prefix handle_sync_repository
