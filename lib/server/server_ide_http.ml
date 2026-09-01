(** Server IDE HTTP — REST endpoints for observational IDE annotations.

    Reads/writes are scoped to the workspace base resolved by
    {!Server_routes_http_routes_workspace.classify_workspace_query}. *)

open Server_auth
open Masc_domain
module Http = Http_server_eio

let base_path_of_state state = (Mcp_server.workspace_config state).base_path
let extract_path_param = Server_utils.extract_path_param

(* The scope vocabulary is shared with the LSP proxy; both surfaces resolve
   through [Server_ide_scope] so a reader cannot address one store here
   and a different one there. Equality re-declaration keeps this module's
   existing field access on [ide_error] unchanged. *)
type ide_error = Server_ide_scope.ide_error =
  { code : string
  ; message : string
  }

let ide_error = Server_ide_scope.ide_error

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

(* RFC-0378 §5.3 — the human half of the anchor contract goes through
   the same mint as the keeper half: the mutation scope names the
   codebase, [file_path] is repo-root-relative, and the pair is minted
   directly. The catalog re-derivation from the raw path string — the
   third attribution vocabulary — is gone with its error taxonomy. *)
let resolve_annotation_post_address ~state ~uri ~file_path =
  match resolve_ide_scope_for_query ~state ~uri with
  | Error _ as err -> err
  | Ok scope ->
    let slug = codebase_of_ide_scope scope in
    (match Agent_observation.Code_address.v ~codebase:slug ~path:file_path with
     | Ok address -> Ok address
     | Error invalid ->
       Error
         (ide_error
            "invalid_file_path"
            (Printf.sprintf
               "file_path must be repo-root-relative (%s)"
               (Agent_observation.Code_address.invalid_to_string invalid))))
;;

let ide_memory_source_kind = "ide_annotation"
let ide_memory_retrieval_status = "annotation_index_only"
let ide_memory_semantic_status = "not_configured"
let ide_memory_episodic_status = "not_configured"

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
  let rows = Keeper_tool_call_log.read_window ~window_hours () in
  let tally = Keeper_tool_call_file_change.classify_all rows in
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
    ; "calls_in_window", `Int (List.length rows)
    ; "changes", `List (List.map Keeper_tool_call_file_change.to_json changes)
    ; "incomplete_over_budget", `Int incomplete_over_budget
    ; "incomplete_malformed", `Int incomplete_malformed
    (* These rows lost even their independent action-radius target. Keep the
       counts explicitly fleet-wide; do not imply that they belong to this
       file or silently omit them. *)
    ; "unattributed_over_budget", `Int unattributed_over_budget
    ; "unattributed_malformed", `Int unattributed_malformed
    ]

(* ── Observation snapshot endpoint (task-1686) ─────────────────────── *)

(** GET /api/v1/ide/observations/snapshot — returns accumulated observation
    data (tool events and annotations) from the IDE bridge observation
    snapshot helper.

    Usage: ?take=true resets accumulators after read (destructive),
           default is non-destructive peek.

    Callers: the dashboard's IDE panels, for real-time updates. *)
let observation_snapshot_handler request reqd =
  let uri = Uri.of_string request.Httpun.Request.target in
  let take =
    match Uri.get_query_param uri "take" with
    | Some "true" -> true
    | _ -> false
  in
  let json = Ide_bridge.observation_snapshot_json ~take in
  let body = json_ok json in
  Http.Response.json_value
    ~request
    ~extra_headers:[ "x-observation-mode", if take then "take" else "peek" ]
    body
    reqd
;;

let keeper_id_not_accepted_error =
  "keeper_id is not accepted; identity is derived from the authentication token"

let annotation_delete_rejected_error = "annotation delete rejected"

(* Machine-readable code for the 403 above. [Ide_annotations.delete]
   flattens not-found and keeper mismatch into one rejection, and the
   auth layer also answers 403 when the token tier lacks the permission
   — the code lets clients tell this rejection apart from a
   credential-tier 403 without matching on the human message. *)
let annotation_delete_rejected_code = "annotation_delete_rejected"

let parse_json_body body_str =
  match Yojson.Safe.from_string body_str with
  | json -> Ok json
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
;;

let json_string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) when s <> "" -> Some s
     | _ -> None)
  | _ -> None
;;

let json_int_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int i) -> Some i
     | Some (`Intlit s) -> int_of_string_opt s
     | _ -> None)
  | _ -> None
;;

let annotation_post_allowed_fields =
  [ "file_path"
  ; "line_start"
  ; "line_end"
  ; "keeper_id"
  ; "kind"
  ; "content"
  ; "goal_id"
  ; "task_id"
  ; "references"
  ]
;;

let validate_annotation_post_fields = function
  | `Assoc fields ->
    (match
       List.find_opt
         (fun (key, _) -> not (List.mem key annotation_post_allowed_fields))
         fields
     with
     | Some (key, _) -> Error (Printf.sprintf "Unknown annotation field: %s" key)
     | None ->
       let rec find_duplicate seen = function
         | [] -> None
         | (key, _) :: rest ->
           if List.mem key seen then Some key else find_duplicate (key :: seen) rest
       in
       (match find_duplicate [] fields with
        | Some key -> Error (Printf.sprintf "Duplicate annotation field: %s" key)
        | None -> Ok ()))
  | _ -> Error "Annotation request must be an object"
;;

let log_keeper_id_not_accepted ~operation ~auth_identity ~requested =
  Log.Server.warn
    "IDE annotation %s rejected client-supplied keeper_id: requested_keeper_id=%S \
     auth_identity=%S"
    operation
    requested
    auth_identity
;;

let log_annotation_delete_rejected ~auth_identity ~id ~reason =
  Log.Server.warn
    "IDE annotation delete rejected: id=%S auth_identity=%S reason=%S"
    id
    auth_identity
    reason
;;

(* task-1736 — bind an annotation
   mutation's keeper_id to the authenticated identity.

   Before B3 the POST/DELETE handlers read keeper_id from a
   client-controlled request body field / query param. Because
   GET /api/v1/ide/annotations echoes keeper_id back in
   [Ide_annotation_types.annotation_to_json], any reader could copy
   another keeper's id and then forge annotations under that id
   (create) or satisfy the [a.keeper_id = keeper_id] ownership check in
   [Ide_annotations.delete] (delete). The acting keeper is now derived
   from the token-bound auth identity threaded by
   [Server_auth.with_token_permission_auth].

   [requested] is the caller-supplied keeper_id (body field or query
   param). It is no longer accepted in any form:
     - absent          -> use the authenticated identity
     - present / blank -> reject with a generic error

   Rejecting the field entirely (rather than treating it as advisory)
   closes the impersonation bypass permanently and makes the security
   contract obvious: the token is the only source of identity. *)
let bind_mutation_keeper_id ~auth_identity ~requested : (string, string) result =
  match requested with
  | None -> Ok auth_identity
  | Some _ -> Error keeper_id_not_accepted_error
;;

(* task-1736 B3 CI: annotation [kind] parsing is sound-partial. An
   absent field defaults to the neutral [Comment] kind (backward
   compatible with clients that omit [kind]); an unrecognized value is
   rejected with a typed error rather than silently coerced to a default
   (CLAUDE.md anti-pattern #2). This replaces the prior optional-value
   defaulting pattern that the determinism-contract gate flagged when B3
   re-indented it into the auth-wrapped handler. *)
let parse_annotation_kind = function
  | None -> Ok Ide_annotation_types.Comment
  | Some raw ->
    (match Ide_annotations.annotation_kind_of_string raw with
     | Some kind -> Ok kind
     | None -> Error "Invalid annotation kind")
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
  |> Http.Router.get "/api/v1/ide/observations/snapshot" observation_snapshot_handler
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
    with_public_read
      (fun state _req reqd ->
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
  |> Http.Router.get "/api/v1/ide/annotations" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         (* RFC-0378 §5.2: the IDE store lives under the
            *server* base_path (single .masc-ide/ tree), not the
            workspace tree returned by [resolve_workspace_base]. The
            latter exists for /api/v1/workspace/{tree,file} routes
            that browse a specific repo's filesystem contents. IDE
            annotation storage must mirror the keeper write
            path, which writes to [server-base/.masc-ide/]. *)
         let base = base_path_of_state state in
         let file_path =
           match Uri.get_query_param uri "file_path" with
           | Some p when p <> "" -> Some p
           | _ -> None
         in
         let keeper_id =
           match Uri.get_query_param uri "keeper_id" with
           | Some k when k <> "" -> Some k
           | _ -> None
         in
         let goal_id =
           match Uri.get_query_param uri "goal_id" with
           | Some g when g <> "" -> Some g
           | _ -> None
         in
         let task_id =
           match Uri.get_query_param uri "task_id" with
           | Some t when t <> "" -> Some t
           | _ -> None
         in
         match resolve_ide_scope_for_query ~state ~uri with
         | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
         | Ok scope ->
           (let codebase = codebase_of_ide_scope scope in
              let filter =
                { Ide_annotation_types.file_path; keeper_id; goal_id; task_id }
              in
              let annotations = Ide_annotations.list ~base_dir:base ~codebase ~filter () in
              let json =
                `List (List.map Ide_annotation_types.annotation_to_json annotations)
              in
              Http.Response.json_value ~compress:true ~request (json_ok json) reqd))
      request
      reqd)
  |> Http.Router.post "/api/v1/ide/annotations" (fun request reqd ->
    (* task-1736 B3: annotation creation is a mutation. It requires a
       token-bound write identity ([CanBroadcast], the keeper write
       tier; no narrower annotation-write permission exists yet in
       [Masc_domain.permission]) instead of [with_public_read], and the
       acting keeper is the resolved [auth_identity] rather than a
       caller-chosen field.

       ASYNC-AUTH NOTE: [with_token_permission_auth] is synchronous and
       reads the workspace auth config / credential store from disk. The
       IDE annotation plane shares this combinator with dashboard and
       tool routes. If Keeper auth latency or disk I/O ever becomes a
       head-of-line blocker here, the correct fix is to make the shared
       auth combinator async with an explicit deadline / circuit breaker
       rather than ad-hoc workarounds in this handler. For the current
       local-file credential store this is not a measured blocker. *)
    with_token_permission_auth
      ~permission:Masc_domain.CanBroadcast
      (fun state auth_identity _req reqd ->
         let uri = Uri.of_string request.target in
         (* RFC-0378 §5.2: the IDE store lives under the
            *server* base_path (single .masc-ide/ tree), not the
            workspace tree returned by [resolve_workspace_base]. The
            latter exists for /api/v1/workspace/{tree,file} routes
            that browse a specific repo's filesystem contents. IDE
            annotation storage must mirror the keeper write
            path, which writes to [server-base/.masc-ide/]. *)
         let base = base_path_of_state state in
         Http.Request.read_body_async reqd (fun body_str ->
           match parse_json_body body_str with
           | Error msg ->
             Http.Response.json_value
               ~status:`Bad_request
               ~request
               (json_error msg)
               reqd
           | Ok json ->
             (match validate_annotation_post_fields json with
              | Error msg ->
                Http.Response.json_value
                  ~status:`Bad_request
                  ~request
                  (json_error ~code:"invalid_annotation_request" msg)
                  reqd
              | Ok () ->
                let find_string key = json_string_field key json in
                let find_int key = json_int_field key json in
                match
                  ( find_string "file_path"
                  , find_int "line_start"
                  , find_int "line_end"
                  , find_string "content" )
                with
                | Some file_path, Some line_start, Some line_end, Some content ->
               (* task-1736 B3: keeper_id is bound to the authenticated
                  identity. A body-supplied keeper_id is rejected outright;
                  the token is the only source of identity. *)
               let requested_keeper_id = find_string "keeper_id" in
               (match
                  bind_mutation_keeper_id ~auth_identity ~requested:requested_keeper_id
                with
                | Error msg ->
                  Option.iter
                    (fun requested ->
                       log_keeper_id_not_accepted
                         ~operation:"create"
                         ~auth_identity
                         ~requested)
                    requested_keeper_id;
                  Http.Response.json_value
                    ~status:`Forbidden
                    ~request
                    (json_error msg)
                    reqd
                | Ok keeper_id ->
                  (match
                     parse_annotation_kind (find_string "kind")
                   with
                   | Error msg ->
                     Http.Response.json_value
                       ~status:`Bad_request
                       ~request
                       (json_error msg)
                       reqd
                   | Ok kind ->
                     let goal_id = find_string "goal_id" in
                     let task_id = find_string "task_id" in
                     let references_json = Yojson.Safe.Util.member "references" json in
                     (match
                        Ide_annotation_types.annotation_references_of_json references_json
                      with
                      | Error msg ->
                        Http.Response.json_value
                          ~status:`Bad_request
                          ~request
                          (json_error ~code:"invalid_references" msg)
                          reqd
                      | Ok references ->
                        (match
                           resolve_annotation_post_address ~state ~uri ~file_path
                         with
                         | Error err ->
                           respond_ide_error ~status:`Bad_request ~request err reqd
                         | Ok address ->
                           (match
                              Ide_annotations.create
                                ~base_dir:base
                                ~codebase:(Agent_observation.Code_address.codebase address)
                                ~keeper_id
                                ~file_path:(Agent_observation.Code_address.path address)
                                ~line_start
                                ~line_end
                                ~kind
                                ~content
                                ?goal_id
                                ?task_id
                                ~references
                                ()
                            with
                            | Ok annotation ->
                              Http.Response.json_value
                                ~status:`Created
                                ~request
                                (json_ok
                                   (Ide_annotation_types.annotation_to_json annotation))
                                reqd
                            | Error msg ->
                              Http.Response.json_value
                                ~status:`Bad_request
                                ~request
                                (json_error ~code:"observation_write_failed" msg)
                                reqd)))))
                | _ ->
                  Http.Response.json_value
                    ~status:`Bad_request
                    ~request
                    (json_error "Missing required fields")
                    reqd)))
      request
      reqd)
  |> Http.Router.prefix_delete "/api/v1/ide/annotations/" (fun request reqd ->
    (* task-1736 B3: deletion is a mutation. It requires a token-bound
       write identity ([CanBroadcast], the keeper write tier; no narrower
       annotation-write permission exists yet in [Masc_domain.permission])
       instead of [with_public_read], and ownership is enforced against the
       resolved [auth_identity] rather than a caller-supplied query param.
       Because [Ide_annotations.delete] only removes an annotation whose
       stored keeper_id equals the passed keeper_id, binding keeper_id to
       auth_identity prevents a caller from successfully deleting another
       keeper's annotation through this route.

       ASYNC-AUTH NOTE: see the POST handler for the synchronous auth
       discussion; the same caveat applies here. *)
    with_token_permission_auth
      ~permission:Masc_domain.CanBroadcast
      (fun state auth_identity _req reqd ->
         let uri = Uri.of_string request.target in
         (* RFC-0378 §5.2: the IDE store lives under the
            *server* base_path (single .masc-ide/ tree), not the
            workspace tree returned by [resolve_workspace_base]. The
            latter exists for /api/v1/workspace/{tree,file} routes
            that browse a specific repo's filesystem contents. IDE
            annotation storage must mirror the keeper write
            path, which writes to [server-base/.masc-ide/]. *)
         let base = base_path_of_state state in
         let id =
           match
             extract_path_param
               ~prefix:"/api/v1/ide/annotations/"
               (Http.Request.path request)
           with
           | Some s when s <> "" -> s
           | _ -> ""
         in
         let requested_keeper_id =
           match Uri.get_query_param uri "keeper_id" with
           | Some k when String.trim k <> "" -> Some (String.trim k)
           | _ -> None
         in
         if id = ""
         then
           Http.Response.json_value
             ~status:`Bad_request
             ~request
             (json_error "Missing id")
             reqd
         else
           match
             bind_mutation_keeper_id ~auth_identity ~requested:requested_keeper_id
           with
           | Error msg ->
             Option.iter
               (fun requested ->
                  log_keeper_id_not_accepted
                    ~operation:"delete"
                    ~auth_identity
                    ~requested)
               requested_keeper_id;
             Http.Response.json_value
               ~status:`Forbidden
               ~request
               (json_error msg)
               reqd
           | Ok keeper_id ->
             (match resolve_ide_scope_for_query ~state ~uri with
              | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
              | Ok scope ->
                (match
                   Ide_annotations.delete
                     ~base_dir:base
                     ~codebase:(codebase_of_ide_scope scope)
                     ~id
                     ~keeper_id
                     ()
                 with
                 | Ok () -> Http.Response.empty ~status:`No_content reqd
                 | Error msg ->
                   log_annotation_delete_rejected ~auth_identity ~id ~reason:msg;
                   Http.Response.json_value
                     ~status:`Forbidden
                     ~request
                     (json_error
                        ~code:annotation_delete_rejected_code
                        annotation_delete_rejected_error)
                     reqd)))
           request
           reqd)
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
  |> Http.Router.get "/api/v1/ide/memory" (fun request reqd ->
    with_public_read
      (fun state _req inner_reqd ->
         let uri = Uri.of_string request.target in
         let base = base_path_of_state state in
         let keeper_id =
           match Uri.get_query_param uri "keeper_id" with
           | Some k when k <> "" -> Some k
           | _ -> None
         in
         match parse_positive_int_query uri "limit" with
         | Error msg ->
           Http.Response.json_value
             ~status:`Bad_request
             ~request
             (json_error msg)
             inner_reqd
         | Ok limit ->
           (* Memory tiers: retrospective, episode, semantic.
              Currently returns annotation-based memory entries.
              Future: integrate with Neo4j/pgvector for semantic search. *)
           (match resolve_ide_scope_for_query ~state ~uri with
            | Error err -> respond_ide_error ~status:`Bad_request ~request err inner_reqd
            | Ok scope ->
              (let codebase = codebase_of_ide_scope scope in
              let filter : Ide_annotation_types.annotation_filter =
                { file_path = None; keeper_id; goal_id = None; task_id = None }
              in
              let annotations = Ide_annotations.list ~base_dir:base ~codebase ~filter () in
              let entries =
                List.map (fun (a : Ide_annotation_types.annotation) ->
                  `Assoc [
                    ("id", `String a.id);
                    ("kind", `String (Ide_annotation_types.annotation_kind_to_string a.kind));
                    ("content", `String a.content);
                    ("file_path", `String a.file_path);
                    ("line_start", `Int a.line_start);
                    ("line_end", `Int a.line_end);
                    ("keeper_id", `String a.keeper_id);
                    ("created_at_ms", `Intlit (Int64.to_string a.created_at_ms));
                    ("source_kind", `String ide_memory_source_kind);
                    ("retrieval_status", `String ide_memory_retrieval_status);
                    ("goal_id", (match a.goal_id with Some g -> `String g | None -> `Null));
                    ("task_id", (match a.task_id with Some t -> `String t | None -> `Null));
                  ])
                (List.filteri (fun i _ -> i < limit) annotations)
              in
              let result = `Assoc [
                ("entries", `List entries);
                ("total", `Int (List.length annotations));
                ("limit", `Int limit);
                ( "contract"
                , `Assoc
                    [ ("source_kind", `String ide_memory_source_kind)
                    ; ("retrieval_status", `String ide_memory_retrieval_status)
                    ; ("semantic_memory_status", `String ide_memory_semantic_status)
                    ; ("episodic_memory_status", `String ide_memory_episodic_status)
                    ] )
              ] in
              let origin = get_origin request in
              let headers =
                Httpun.Headers.of_list
                  (("content-type", "application/json") :: cors_headers origin)
              in
              let body = Yojson.Safe.to_string result in
              let response = Httpun.Response.create ~headers `OK in
              Httpun.Reqd.respond_with_string inner_reqd response body)))
      request
      reqd)
;;
