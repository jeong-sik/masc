(** Server IDE HTTP — REST endpoints for the IDE plane: file activity,
    keeper events, and presence.

    Reads/writes are scoped to the workspace base resolved by
    {!Server_routes_http_routes_workspace.classify_workspace_query}. *)

open Server_auth
open Masc_domain
module Http = Http_server_eio

let base_path_of_state state = (Mcp_server.workspace_config state).base_path

(* The scope vocabulary is shared with the LSP proxy; both surfaces resolve
   through [Server_ide_scope] so a reader cannot address one store here
   and a different one there. Equality re-declaration keeps this module's
   existing field access on [ide_error] unchanged. *)
type ide_error = Server_ide_scope.ide_error =
  { code : string
  ; message : string
  }

let json_error ?code message =
  let fields = [ "ok", `Bool false; "error", `String message ] in
  let fields =
    match code with
    | None -> fields
    | Some code -> fields @ [ "code", `String code ]
  in
  `Assoc fields
;;

let respond_ide_error ~status ~request err reqd =
  Http.Response.json_value
    ~status
    ~request
    (json_error ~code:err.code err.message)
    reqd
;;


type ide_scope = Server_ide_scope.ide_scope = Scope_codebase of { slug : string }

let codebase_of_ide_scope = Server_ide_scope.codebase_of_ide_scope
let resolve_ide_scope_for_query = Server_ide_scope.resolve_ide_scope_for_query

let json_ok data = `Assoc [ "ok", `Bool true; "data", data ]

let file_activity_window_hours uri =
  match Uri.get_query_param uri "window_hours" with
  | None -> Ok Server_dashboard_http_keeper_api.file_changes_default_window_hours
  | Some raw -> (
      match float_of_string_opt (String.trim raw) with
      | Some hours when hours > 0. ->
        Ok (Float.min hours Server_dashboard_http_keeper_api.file_changes_max_window_hours)
      | Some _ | None ->
        Error (Printf.sprintf "window_hours must be a positive number: %s" raw))

let required_query_param uri name =
  match Uri.get_query_param uri name with
  | Some raw when String.trim raw <> "" -> Ok (String.trim raw)
  | Some _ | None -> Error (Printf.sprintf "%s is required" name)

let optional_query_param uri name =
  match Uri.get_query_param uri name with
  | Some raw when String.trim raw <> "" -> Some (String.trim raw)
  | Some _ | None -> None

let canonical_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ -> path

let resolve_file_activity_repository ~base_path ~repo_id =
  match Repo_store.load_all ~base_path with
  | Error detail -> Error (`Unavailable detail)
  | Ok repositories -> (
      let matches =
        match repo_id with
        | Some repo_id ->
          List.filter
            (fun (repository : Repo_manager_types.repository) ->
              String.equal repository.id repo_id)
            repositories
        | None ->
          let project_path = canonical_path base_path in
          List.filter
            (fun (repository : Repo_manager_types.repository) ->
              String.equal
                (canonical_path (Repo_store.local_path ~base_path repository))
                project_path)
            repositories
      in
      match matches with
      | [] ->
        Error
          (`Not_found
            (match repo_id with
             | Some repo_id -> "repository is not registered: " ^ repo_id
             | None ->
               "the project base path is not a registered repository checkout"))
      | _ :: _ :: _ ->
        Error
          (`Ambiguous
            (match repo_id with
             | Some repo_id ->
               "more than one registered repository uses id " ^ repo_id
             | None ->
               "more than one registered repository resolves to the project base path"))
      | [ repository ] -> (
          match Agent_observation.canonical_url_of_remote repository.url with
          | Some codebase -> Ok (repository, codebase)
          | None ->
            Error
              (`No_codebase
                (Printf.sprintf
                   "repository %s has no canonical codebase"
                   repository.id))))

let file_activity_json ~codebase ~repo_id ~file_path ~window_hours =
  let tally = Keeper_tool_call_log.file_change_tally ~window_hours () in
  let changes =
    Keeper_tool_call_file_change.for_repo_file
      ~repo_id ~relative_path:file_path tally.changes
  in
  let incomplete =
    Keeper_tool_call_file_change.unreadable_for_repo_file
      ~repo_id ~relative_path:file_path tally.unreadable_rows
  in
  let count_reason reason =
    List.fold_left
      (fun total row -> if row.Keeper_tool_call_file_change.ur_reason = reason then total + 1 else total)
      0
  in
  let incomplete_over_budget = count_reason Keeper_tool_call_file_change.Input_exceeded_log_budget incomplete in
  let incomplete_malformed =
    List.fold_left
      (fun total row ->
        match row.Keeper_tool_call_file_change.ur_reason with
        | Keeper_tool_call_file_change.Malformed _ -> total + 1
        | Keeper_tool_call_file_change.Input_exceeded_log_budget -> total)
      0 incomplete
  in
  let unattributed =
    List.filter
      (fun row -> Option.is_none row.Keeper_tool_call_file_change.ur_location)
      tally.unreadable_rows
  in
  let unattributed_over_budget =
    count_reason Keeper_tool_call_file_change.Input_exceeded_log_budget unattributed
  in
  let unattributed_malformed =
    List.length unattributed - unattributed_over_budget
  in
  `Assoc
    [ "schema", `String "masc.ide.file_activity.v1"
    ; "codebase", `String codebase
    ; "repo_id", `String repo_id
    ; "file_path", `String file_path
    ; "window_hours", `Float window_hours
      (* Same source as the keeper route: the tally already partitions what
         was read. *)
    ; "calls_in_window", `Int (Keeper_tool_call_file_change.rows_counted tally)
    ; "changes", `List (List.map Keeper_tool_call_file_change.to_json changes)
    ; "incomplete_over_budget", `Int incomplete_over_budget
    ; "incomplete_malformed", `Int incomplete_malformed
    (* These rows lost even their independent action-radius target. Keep the
       counts explicitly fleet-wide; do not imply that they belong to this
       file or silently omit them. *)
    ; "unattributed_over_budget", `Int unattributed_over_budget
    ; "unattributed_malformed", `Int unattributed_malformed
    ]

;;

let parse_int_query uri name =
  match Uri.get_query_param uri name with
  | None -> Ok None
  | Some raw ->
    let value = String.trim raw in
    (match int_of_string_opt value with
     | Some n -> Ok (Some n)
     | None -> Error (Printf.sprintf "%s must be an integer" name))
;;

let parse_positive_int_query ?(default = 50) ?max_value uri name =
  match parse_int_query uri name with
  | Error _ as err -> err
  | Ok None -> Ok default
  | Ok (Some n) when n > 0 ->
    let n =
      match max_value with
      | Some max_value -> min n max_value
      | None -> n
    in
    Ok n
  | Ok (Some _) -> Error (Printf.sprintf "%s must be greater than 0" name)
;;

let parse_non_negative_int_query ?(default = 0) uri name =
  match parse_int_query uri name with
  | Error _ as err -> err
  | Ok None -> Ok default
  | Ok (Some n) when n >= 0 -> Ok n
  | Ok (Some _) -> Error (Printf.sprintf "%s must be greater than or equal to 0" name)
;;

let parse_pagination_query ?max_limit uri =
  match parse_positive_int_query ?max_value:max_limit uri "limit" with
  | Error _ as err -> err
  | Ok limit ->
    (match parse_non_negative_int_query uri "offset" with
     | Error _ as err -> err
     | Ok offset -> Ok (limit, offset))
;;

let event_kind_param uri =
  match Uri.get_query_param uri "kind" with
  | None -> Ok None
  | Some raw ->
    (match String.trim raw with
     | "" | "all" -> Ok None
     | kind ->
       (match Ide_bridge.event_kind_of_string kind with
        | Some parsed -> Ok (Some parsed)
        | None -> Error "kind must be one of tool, turn, pr, all"))
;;

let keeper_id_param uri =
  match Uri.get_query_param uri "keeper_id" with
  | Some k when String.trim k <> "" -> Some (String.trim k)
  | _ ->
    (match Uri.get_query_param uri "keeper" with
     | Some k when String.trim k <> "" -> Some (String.trim k)
     | _ -> None)
;;

let runtime_id_and_branch state =
  let base = base_path_of_state state in
  let runtime_id =
    let base_name = Filename.basename base in
    if base_name = "" then "masc-runtime" else base_name
  in
  let branch =
    let head_path = Filename.concat base ".git/HEAD" in
    if Fs_compat.file_exists head_path
    then (
      match Fs_compat.load_file head_path with
      | exception exn ->
        Log.Server.warn
          "build_presence_snapshot: read %s failed, defaulting branch to 'main': %s"
          head_path
          (Printexc.to_string exn);
        "main"
      | content ->
        let ref_line =
          match String.split_on_char '\n' content with
          | first :: _ -> first
          | [] -> ""
        in
        if String.starts_with ~prefix:"ref: refs/heads/" ref_line
        then String.sub ref_line 16 (String.length ref_line - 16)
        else ref_line)
    else "main"
  in
  runtime_id, branch
;;

let build_presence_snapshot state =
  let base = base_path_of_state state in
  let runtime_id, branch = runtime_id_and_branch state in
  let config = Mcp_server.workspace_config state in
  let entries =
    Workspace.get_active_agents config
    |> List.filter_map (fun (agent : Masc_domain.agent) ->
         let keeper_name =
           Option.bind agent.meta (fun meta -> meta.Masc_domain.keeper_name)
         in
         let presence_status =
           match agent.status with
           | Masc_domain.Active | Masc_domain.Busy -> Some "active"
           | Masc_domain.Listening -> Some "idle"
           | Masc_domain.Inactive -> None
         in
         match keeper_name, presence_status with
         | None, _ | _, None -> None
         | Some keeper_id, Some status ->
           let last_seen_ms =
             Server_presence.last_seen_ms ~context:"IDE presence" agent
           in
           Some
             (`Assoc
               [ "keeper_id", `String keeper_id
               ; "workspace_label", `String (Filename.basename base)
               ; "branch", `String branch
               ; "role", `String "keeper"
               ; "status", `String status
               ; "last_seen_ms", `Intlit (Int64.to_string last_seen_ms)
               ]))
  in
  `Assoc
    [ "runtime_id", `String runtime_id
    ; "branch", `String branch
    ; "supervisor", `String "local"
    ; "connected", `Bool true
    ; "entries", `List entries
    ]
;;

let add_routes router =
  Ide_bridge.install_agent_observation_sinks ();
  router
  |> Http.Router.get "/api/v1/agents" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let config = Mcp_server.workspace_config state in
         let agents = Workspace.get_active_agents config in
         let entries =
           List.map
             (fun (agent : Masc_domain.agent) ->
                `Assoc
                  [ "name", `String agent.name
                  ; "status", `String (Masc_domain.agent_status_to_string agent.status)
                  ; "current_task", Json_util.string_opt_to_json agent.current_task
                  ; "model", `Null
                  ])
             agents
         in
         Http.Response.json_value
           ~compress:true
           ~request
           (json_ok (`Assoc [ "agents", `List entries ]))
           reqd)
      request
      reqd)
  |> Http.Router.get "/api/v1/status" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let config = (Mcp_server.workspace_config state) in
         let workspace_state = Workspace.read_state config in
         let tempo = Tempo.get_tempo config in
         let json = `Assoc [
           "cluster", `String (Env_config_core.cluster_name ());
           "project", `String workspace_state.project;
           "tempo_interval_s", `Float tempo.current_interval_s;
           "paused", `Bool workspace_state.paused;
         ] in
         Http.Response.json_value
           ~compress:true
           ~request
           (json_ok json)
           reqd)
      request
      reqd)
  |> Http.Router.get "/api/v1/ide/file-activity" (fun request reqd ->
    (* Same data, same gate as [/api/v1/keepers/:name/file-changes]: every
       row carries the exact text a keeper wrote (before/after strings, whole
       file bodies), fleet-wide over the window. A public read here was a
       second door onto content the keeper route keeps behind CanAdmin. *)
    with_token_permission_auth ~permission:Masc_domain.CanAdmin
      (fun state _agent_name _req reqd ->
        let uri = Uri.of_string request.target in
        match required_query_param uri "file_path", file_activity_window_hours uri with
        | Error detail, _ | _, Error detail ->
          Http.Response.json_value
            ~status:`Bad_request ~request (json_error detail) reqd
        | Ok file_path, Ok window_hours ->
          let base_path = base_path_of_state state in
          let requested_repo_id = optional_query_param uri "repo_id" in
          (match
             resolve_file_activity_repository ~base_path
               ~repo_id:requested_repo_id
           with
              | Error (`Unavailable detail) ->
                Http.Response.json_value
                  ~status:`Internal_server_error ~request
                  (json_error ~code:"repository_catalog_unavailable" detail)
                  reqd
              | Error (`Not_found detail) ->
                Http.Response.json_value
                  ~status:`Not_found ~request
                  (json_error ~code:"repository_not_found" detail)
                  reqd
              | Error (`Ambiguous detail) ->
                Http.Response.json_value
                  ~status:`Conflict ~request
                  (json_error ~code:"repository_ambiguous" detail)
                  reqd
              | Error (`No_codebase detail) ->
                Http.Response.json_value
                  ~status:`Bad_request ~request
                  (json_error ~code:"repository_has_no_codebase" detail)
                  reqd
              | Ok (repository, codebase) ->
                let repo_id = repository.Repo_manager_types.id in
                (match Agent_observation.Code_address.v ~codebase ~path:file_path with
                 | Error invalid ->
                   Http.Response.json_value
                     ~status:`Bad_request ~request
                     (json_error
                        ~code:"invalid_file_path"
                        (Agent_observation.Code_address.invalid_to_string invalid))
                     reqd
                 | Ok _ ->
                   Http.Response.json_value ~compress:true ~request
                     (json_ok
                        (file_activity_json
                           ~codebase ~repo_id ~file_path ~window_hours))
                     reqd)))
      request reqd)
  |> Http.Router.get "/api/v1/ide/events" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         match event_kind_param uri with
         | Error msg ->
           Http.Response.json_value
             ~status:`Bad_request
             ~request
             (json_error msg)
             reqd
         | Ok kind ->
           (match parse_pagination_query ~max_limit:200 uri with
            | Error msg ->
              Http.Response.json_value
                ~status:`Bad_request
                ~request
                (json_error msg)
                reqd
            | Ok (limit, offset) ->
              let base = base_path_of_state state in
              (match resolve_ide_scope_for_query ~state ~uri with
               | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
               | Ok scope ->
                 (let keeper_id = keeper_id_param uri in
                    let codebase = codebase_of_ide_scope scope in
                    let events =
                      Ide_bridge.list_events
                        ~base_path:base
                        ~codebase
                        ?kind
                        ?keeper_id
                        ~limit
                        ~offset
                        ()
                    in
                    let kind_json =
                      match kind with
                      | Some k -> `String (Ide_bridge.event_kind_to_string k)
                      | None -> `String "all"
                    in
                    let result =
                      `Assoc
                        [ "events", `List events
                        ; "count", `Int (List.length events)
                        ; "kind", kind_json
                        ; "limit", `Int limit
                        ; "offset", `Int offset
                        ]
                    in
                    Http.Response.json_value
                      ~compress:true
                      ~request
                      (json_ok result)
                      reqd))))
      request
      reqd)
  (* [build_presence_snapshot] extracted in main — conflict resolved by taking
     main's helper call instead of our inline construction. *)
  |> Http.Router.get "/api/v1/ide/presence" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let snapshot = build_presence_snapshot state in
         Http.Response.json_value
           ~compress:true
           ~request
           (json_ok snapshot)
           reqd)
      request
      reqd)
;;
