(** Server IDE HTTP — REST endpoints for observational IDE annotations
    and code regions.

    Reads/writes are scoped to the workspace base resolved by
    {!Server_routes_http_routes_workspace.classify_workspace_query}. *)

open Server_auth
open Server_utils
open Masc_domain
module Http = Http_server_eio

let base_path_of_state state = (Mcp_server.workspace_config state).base_path
let extract_path_param = Server_utils.extract_path_param

type ide_error =
  { code : string
  ; message : string
  }

let ide_error code message = { code; message }

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

let resolve_workspace_base ~state ~uri =
  let project_base = base_path_of_state state in
  let config = (Mcp_server.workspace_config state) in
  let lookup_repository repo_id =
    match Repo_store.find ~base_path:project_base repo_id with
    | Ok repo -> Some (Repo_store.local_path ~base_path:project_base repo)
    | Error _ -> None
  in
  let lookup_playground name =
    match Keeper_meta_store.read_meta config name with
    | Ok (Some m) -> Some (Keeper_sandbox.host_root_abs_of_meta ~config m)
    | _ -> None
  in
  let exists_dir p = Sys.file_exists p && Sys.is_directory p in
  Server_routes_http_routes_workspace.classify_workspace_query
    ~project_base
    ~lookup_repository
    ~lookup_playground
    ~exists_dir
    ~repo_param:(Uri.get_query_param uri "repo_id")
    ~keeper_param:(Uri.get_query_param uri "keeper")
;;

let nonempty_query_param uri key =
  match Uri.get_query_param uri key with
  | Some raw ->
    let value = String.trim raw in
    if String.equal value "" then None else Some value
  | None -> None
;;

type ide_scope =
  | Scope_canonical_url of
      { raw : string
      ; slug : string
      }
  | Scope_repo_id of
      { repo_id : string
      ; slug : string
      }
  | Scope_keeper_lane of { keeper_id : string }

(* Keeper-lane reads address the repo-unattributed observation bucket
   ([_orphan/] on disk). A keeper turn is a keeper-timeline fact, not a
   repo fact: turn events and coordination tool events carry no file, so
   they are written without a [By_url] partition. Before this scope
   existed, read routes could only address [By_url] partitions, which made
   that data unreachable from any API while it kept accumulating — the
   read/write split-brain from the 2026-07-07 IDE observation audit. *)
let partition_of_ide_scope = function
  | Scope_canonical_url { slug; _ } | Scope_repo_id { slug; _ } ->
    Ide_paths.By_url slug
  | Scope_keeper_lane _ -> Ide_paths.Legacy_default
;;

let resolve_ide_scope_for_query ~state ~uri =
  let project_base = base_path_of_state state in
  match
    ( nonempty_query_param uri "canonical_url"
    , nonempty_query_param uri "repo_id"
    , nonempty_query_param uri "keeper_lane" )
  with
  | None, None, None ->
    Error
      (ide_error
         "missing_ide_scope"
         "IDE scope is required; pass repo_id, canonical_url, or keeper_lane")
  | Some _, Some _, _ | Some _, _, Some _ | _, Some _, Some _ ->
    Error
      (ide_error
         "conflicting_ide_scope"
         "IDE scope must specify exactly one of repo_id, canonical_url, or keeper_lane")
  | Some raw, None, None ->
    (match Ide_paths.canonical_url_of_remote raw with
     | Some slug -> Ok (Scope_canonical_url { raw; slug })
     | None -> Error (ide_error "invalid_canonical_url" "canonical_url is invalid"))
  | None, Some repo_id, None ->
    (match Repo_store.find_url_by_id ~base_path:project_base repo_id with
     | None -> Error (ide_error "unmatched_repo_id" "repo_id does not match a configured repository")
     | Some url ->
       (match Ide_paths.canonical_url_of_remote url with
        | Some slug -> Ok (Scope_repo_id { repo_id; slug })
        | None ->
          Error
            (ide_error
               "no_canonical_url"
               "repo_id has no valid canonical URL")))
  | None, None, Some keeper_id ->
    (* [keeper_id] is a filter value compared against stored event fields,
       never a filesystem path, so no registry lookup gates it: validating
       against currently-active keepers would hide the history of any
       keeper that is offline or renamed. An unknown id returns an
       explicitly keeper_lane-scoped empty result. *)
    Ok (Scope_keeper_lane { keeper_id })
;;

(* Mutations stay repo-scoped: an observation write without repo identity
   is exactly the orphan-bucket growth the keeper-lane read scope exists
   to expose, so the API refuses to mint more of it. *)
let resolve_partition_for_mutation ~state ~uri =
  match resolve_ide_scope_for_query ~state ~uri with
  | Ok (Scope_keeper_lane _) ->
    Error
      (ide_error
         "keeper_lane_read_only"
         "keeper_lane is a read-only scope; mutations require repo_id or canonical_url")
  | Ok scope -> Ok (partition_of_ide_scope scope)
  | Error _ as err -> err
;;

(* The lane keeper is the mandatory filter for keeper-lane reads; a
   contradictory explicit [keeper_id] param is a caller bug surfaced as a
   typed error instead of silently returning another keeper's data. *)
let keeper_filter_for_scope ~scope ~requested_keeper_id =
  match scope with
  | Scope_keeper_lane { keeper_id = lane } ->
    (match requested_keeper_id with
     | Some k when not (String.equal k lane) ->
       Error
         (ide_error
            "keeper_lane_filter_conflict"
            "keeper_id filter must match the keeper_lane scope")
     | Some _ | None -> Ok (Some lane))
  | Scope_canonical_url _ | Scope_repo_id _ -> Ok requested_keeper_id
;;

let with_keeper_lane_read_auth ~state ~request ~reqd ~scope continue =
  match scope with
  | Scope_canonical_url _ | Scope_repo_id _ -> continue ()
  | Scope_keeper_lane { keeper_id = lane } ->
    let base_path = base_path_of_state state in
    (match
       authorize_token_bound_permission_request
         ~base_path
         ~permission:Masc_domain.CanReadState
         request
     with
     | Error err -> respond_auth_error request reqd err
     | Ok agent_name when String.equal agent_name lane -> continue ()
     | Ok _ ->
       respond_ide_error
         ~status:`Forbidden
         ~request
         (ide_error
            "keeper_lane_forbidden"
            "keeper_lane reads require a bearer token for the requested keeper")
         reqd)
;;

type annotation_scope_error =
  | File_path_repo_id_mismatch
  | File_path_canonical_url_mismatch

let annotation_scope_error_message = function
  | File_path_repo_id_mismatch -> "file_path does not belong to requested repo_id"
  | File_path_canonical_url_mismatch ->
    "file_path does not belong to requested canonical_url"
;;

let annotation_scope_error_code = function
  | File_path_repo_id_mismatch -> "repo_mismatch"
  | File_path_canonical_url_mismatch -> "canonical_url_mismatch"
;;

let validate_annotation_post_scope ~state ~uri ~file_path =
  if Filename.is_relative file_path then Ok ()
  else (
    let project_base = base_path_of_state state in
    match nonempty_query_param uri "canonical_url" with
    | Some canonical_url ->
      (match Ide_paths.canonical_url_of_remote canonical_url with
       | None -> Ok ()
       | Some requested_slug ->
         (match Repo_store.find_repo_by_path_prefix ~base_path:project_base file_path with
          | Some (repo, _) ->
            (match Ide_paths.canonical_url_of_remote repo.url with
             | Some actual_slug when String.equal actual_slug requested_slug -> Ok ()
             | Some _ | None -> Error File_path_canonical_url_mismatch)
          | None -> Error File_path_canonical_url_mismatch))
    | None ->
      (match nonempty_query_param uri "repo_id" with
       | None -> Ok ()
       | Some requested_repo_id ->
         (match Repo_store.find ~base_path:project_base requested_repo_id with
          | Error _ -> Ok ()
          | Ok _ ->
            (match Repo_store.find_repo_by_path_prefix ~base_path:project_base file_path with
             | Some (repo, _) when String.equal repo.id requested_repo_id -> Ok ()
             | Some _ | None -> Error File_path_repo_id_mismatch))))
;;

let resolve_partition_for_annotation_post ~state ~uri ~file_path =
  match resolve_partition_for_mutation ~state ~uri with
  | Error _ as err -> err
  | Ok partition ->
    (match validate_annotation_post_scope ~state ~uri ~file_path with
     | Ok () -> Ok partition
     | Error err ->
       Error
         (ide_error
            (annotation_scope_error_code err)
            (annotation_scope_error_message err)))
;;

let ide_memory_source_kind = "ide_annotation"
let ide_memory_retrieval_status = "annotation_index_only"
let ide_memory_semantic_status = "not_configured"
let ide_memory_episodic_status = "not_configured"

let json_ok data = `Assoc [ "ok", `Bool true; "data", data ]

(* ── Observation snapshot endpoint (task-1686) ─────────────────────── *)

(** GET /api/v1/ide/observations/snapshot — returns accumulated observation
    data (tool events, PR events, turn events, write regions, annotations)
    from the IDE bridge observation snapshot helper.

    Usage: ?take=true resets accumulators after read (destructive),
           default is non-destructive peek.

    Callers: IDE Observation Plane frontend for real-time dashboard. *)
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

let cursor_focus_mode_field = function
  | `Assoc fields ->
    (match List.assoc_opt "focus_mode" fields with
     | None -> Ok None
     | Some (`String mode) ->
       (match Ide_bridge.cursor_focus_mode_of_string mode with
        | Some mode -> Ok (Some mode)
        | None -> Error "focus_mode must be one of reading, editing, reviewing, planning")
     | Some _ -> Error "focus_mode must be a string")
  | _ -> Ok None
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

(* task-1736 (IDE Observation Plane v2, axis B3) — bind an annotation
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

let file_path_param uri =
  match Uri.get_query_param uri "file_path" with
  | Some p when String.trim p <> "" -> Some (String.trim p)
  | _ -> None
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
  let entries =
    let agents = Client_registry_eio.list_active ~within_seconds:300.0 () in
    List.map
      (fun (a : Client_identity.t) ->
         `Assoc
           [ "keeper_id", `String a.Client_identity.agent_name
           ; "workspace_label", `String (Filename.basename base)
           ; "branch", `String branch
           ; "role", `String "keeper"
           ; "status", `String "active"
           ; ( "last_seen_ms"
             , `Intlit (Printf.sprintf "%.0f" (a.Client_identity.registered_at *. 1000.0))
             )
           ])
      agents
  in
  `Assoc
    [ "runtime_id", `String runtime_id
    ; "branch", `String branch
    ; "supervisor", `String "local"
    ; "connected", `Bool true
    ; "entries", `List entries
    ]
;;

(* [keeper_id] is scope-resolved by the caller ([keeper_filter_for_scope]):
   a keeper-lane scope forces its lane keeper, repo scopes pass the optional
   [?keeper_id] query filter through unchanged. *)
let build_cursor_snapshot state uri ~partition ~keeper_id ~limit ~offset =
  let base = base_path_of_state state in
  let runtime_id, branch = runtime_id_and_branch state in
  let file_path = file_path_param uri in
  let cursors =
    Ide_bridge.list_cursors
      ~base_path:base
      ~partition
      ?keeper_id
      ?file_path
      ~limit
      ~offset
      ()
  in
  `Assoc
    [ "runtime_id", `String runtime_id
    ; "branch", `String branch
    ; "connected", `Bool true
    ; "cursors", `List cursors
    ; "count", `Int (List.length cursors)
    ; "limit", `Int limit
    ; "offset", `Int offset
    ]
;;

let add_routes router =
  Ide_bridge.install_agent_observation_sinks ();
  router
  |> Http.Router.get "/api/v1/ide/observations/snapshot" observation_snapshot_handler
  |> Http.Router.get "/api/v1/agents" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let agents = Client_registry_eio.list_active ~within_seconds:300.0 () in
         let entries =
           List.map
             (fun (a : Client_identity.t) ->
                `Assoc
                  [ "name", `String a.Client_identity.agent_name
                  ; "status", `String "active"
                  ; "current_task", `Null
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
  |> Http.Router.get "/api/v1/ide/annotations" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         (* RFC-0128 §4.2 PR-8: partition storage lives under the
            *server* base_path (single .masc-ide/ tree), not the
            workspace tree returned by [resolve_workspace_base]. The
            latter exists for /api/v1/workspace/{tree,file} routes
            that browse a specific repo's filesystem contents. IDE
            annotation/region storage must mirror the keeper write
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
           (match keeper_filter_for_scope ~scope ~requested_keeper_id:keeper_id with
            | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
            | Ok keeper_id ->
              with_keeper_lane_read_auth ~state ~request ~reqd ~scope (fun () ->
              let partition = partition_of_ide_scope scope in
              let filter =
                { Ide_annotation_types.file_path; keeper_id; goal_id; task_id }
              in
              let annotations =
                Ide_annotations.list
                  ~base_dir:base
                  ~partition
                  ~filter
                  ()
              in
              let json =
                `List (List.map Ide_annotation_types.annotation_to_json annotations)
              in
              Http.Response.json_value
                ~compress:true
                ~request
                (json_ok json)
                reqd)))
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
         (* RFC-0128 §4.2 PR-8: partition storage lives under the
            *server* base_path (single .masc-ide/ tree), not the
            workspace tree returned by [resolve_workspace_base]. The
            latter exists for /api/v1/workspace/{tree,file} routes
            that browse a specific repo's filesystem contents. IDE
            annotation/region storage must mirror the keeper write
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
                     let board_post_id = find_string "board_post_id" in
                     let comment_id = find_string "comment_id" in
                     let pr_id = find_string "pr_id" in
                     let git_ref = find_string "git_ref" in
                     let log_id = find_string "log_id" in
                     let session_id = find_string "session_id" in
                     let operation_id = find_string "operation_id" in
                     let worker_run_id = find_string "worker_run_id" in
                     (match
                        resolve_partition_for_annotation_post ~state ~uri ~file_path
                      with
                      | Error err ->
                        respond_ide_error ~status:`Bad_request ~request err reqd
                      | Ok partition ->
                        (match
                           Ide_annotations.create
                             ~base_dir:base
                             ~partition
                             ~keeper_id
                             ~file_path
                             ~line_start
                             ~line_end
                             ~kind
                             ~content
                             ?goal_id
                             ?task_id
                             ?board_post_id
                             ?comment_id
                             ?pr_id
                             ?git_ref
                             ?log_id
                             ?session_id
                             ?operation_id
                             ?worker_run_id
                             ()
                         with
                         | Ok annotation ->
                           Http.Response.json_value
                             ~status:`Created
                             ~request
                             (json_ok (Ide_annotation_types.annotation_to_json annotation))
                             reqd
                         | Error msg ->
                           Http.Response.json_value
                             ~status:`Bad_request
                             ~request
                             (json_error ~code:"observation_write_failed" msg)
                             reqd))))
             | _ ->
               Http.Response.json_value
                 ~status:`Bad_request
                 ~request
                 (json_error "Missing required fields")
                 reqd))
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
         (* RFC-0128 §4.2 PR-8: partition storage lives under the
            *server* base_path (single .masc-ide/ tree), not the
            workspace tree returned by [resolve_workspace_base]. The
            latter exists for /api/v1/workspace/{tree,file} routes
            that browse a specific repo's filesystem contents. IDE
            annotation/region storage must mirror the keeper write
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
             (match resolve_partition_for_mutation ~state ~uri with
              | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
              | Ok partition ->
                (match
                   Ide_annotations.delete ~base_dir:base ~partition ~id ~keeper_id ()
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
  |> Http.Router.get "/api/v1/ide/regions" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         (* RFC-0128 §4.2 PR-8: partition storage lives under the
            *server* base_path (single .masc-ide/ tree), not the
            workspace tree returned by [resolve_workspace_base]. The
            latter exists for /api/v1/workspace/{tree,file} routes
            that browse a specific repo's filesystem contents. IDE
            annotation/region storage must mirror the keeper write
            path, which writes to [server-base/.masc-ide/]. *)
         let base = base_path_of_state state in
         let file_path =
           match Uri.get_query_param uri "file_path" with
           | Some p when p <> "" -> Some p
           | _ -> None
         in
         match resolve_ide_scope_for_query ~state ~uri with
         | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
         | Ok scope ->
           with_keeper_lane_read_auth ~state ~request ~reqd ~scope (fun () ->
           let partition = partition_of_ide_scope scope in
           let regions =
             Ide_region_tracker.read_regions
               ~base_dir:base
               ~partition
               ?file_path
               ()
           in
           (* [read_regions] has no keeper filter; a keeper-lane read
              narrows to the lane keeper here so it never exposes another
              keeper's lane data under this scope. *)
           let regions =
             match scope with
             | Scope_keeper_lane { keeper_id } ->
               List.filter
                 (fun (r : Ide_annotation_types.code_region) ->
                   String.equal r.keeper_id keeper_id)
                 regions
             | Scope_canonical_url _ | Scope_repo_id _ -> regions
           in
           let json = `List (List.map Ide_annotation_types.region_to_json regions) in
           Http.Response.json_value
             ~compress:true
             ~request
             (json_ok json)
             reqd)
      )
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
                 (match
                    keeper_filter_for_scope
                      ~scope
                      ~requested_keeper_id:(keeper_id_param uri)
                  with
                  | Error err ->
                    respond_ide_error ~status:`Bad_request ~request err reqd
                  | Ok keeper_id ->
                    with_keeper_lane_read_auth ~state ~request ~reqd ~scope (fun () ->
                    let partition = partition_of_ide_scope scope in
                    let events =
                      Ide_bridge.list_events
                        ~base_path:base
                        ~partition
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
                      reqd)))))
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
  |> Http.Router.get "/api/v1/ide/cursors" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         match parse_pagination_query ~max_limit:200 uri with
         | Error msg ->
           Http.Response.json_value
             ~status:`Bad_request
             ~request
             (json_error msg)
             reqd
         | Ok (limit, offset) ->
           (match resolve_ide_scope_for_query ~state ~uri with
            | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
            | Ok scope ->
              (match
                 keeper_filter_for_scope
                   ~scope
                   ~requested_keeper_id:(keeper_id_param uri)
               with
               | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
               | Ok keeper_id ->
                 with_keeper_lane_read_auth ~state ~request ~reqd ~scope (fun () ->
                 let partition = partition_of_ide_scope scope in
                 let snapshot =
                   build_cursor_snapshot state uri ~partition ~keeper_id ~limit ~offset
                 in
                 Http.Response.json_value
                   ~compress:true
                   ~request
                   (json_ok snapshot)
                   reqd))))
      request
      reqd)
  |> Http.Router.post "/api/v1/ide/cursors" (fun request reqd ->
    (* Cursor writes mutate the same observation plane as annotations.
       They use the same write tier ([CanBroadcast]) and the same
       identity rule: the token-bound [auth_identity] is the only source
       of keeper_id; a body-supplied keeper_id is rejected outright. *)
    with_token_permission_auth
      ~permission:Masc_domain.CanBroadcast
      (fun state auth_identity _req reqd ->
         let base = base_path_of_state state in
         let uri = Uri.of_string request.target in
         Http.Request.read_body_async reqd (fun body_str ->
           match parse_json_body body_str with
           | Error msg ->
             Http.Response.json_value
               ~status:`Bad_request
               ~request
               (json_error msg)
               reqd
           | Ok json ->
             let find_string key = json_string_field key json in
             let find_int key = json_int_field key json in
             (match find_string "file_path", find_int "line" with
              | Some file_path, Some line when line >= 1 ->
                let column = find_int "column" in
                (match column with
                 | Some value when value < 0 ->
                   Http.Response.json_value
                     ~status:`Bad_request
                     ~request
                     (json_error "column must be >= 0")
                     reqd
                 | _ ->
                   let source =
                     match find_string "source" with
                     | Some source -> source
                     | None ->
                       (* DET-OK: absent source preserves legacy cursor telemetry. *)
                       "editor"
                   in
                   (match cursor_focus_mode_field json with
                 | Error msg ->
                   Http.Response.json_value
                     ~status:`Bad_request
                     ~request
                     (json_error ~code:"invalid_focus_mode" msg)
                     reqd
                 | Ok focus_mode ->
                   let requested_keeper_id = find_string "keeper_id" in
                   (match
                      bind_mutation_keeper_id ~auth_identity ~requested:requested_keeper_id
                    with
                    | Error msg ->
                      Option.iter
                        (fun requested ->
                           log_keeper_id_not_accepted
                             ~operation:"cursor"
                             ~auth_identity
                             ~requested)
                        requested_keeper_id;
                      Http.Response.json_value
                        ~status:`Forbidden
                        ~request
                        (json_error msg)
                        reqd
                    | Ok keeper_id ->
                      (match resolve_partition_for_mutation ~state ~uri with
                       | Error err -> respond_ide_error ~status:`Bad_request ~request err reqd
                       | Ok partition ->
                         (match
                            Ide_bridge.ingest_cursor_event
                              ~base_path:base
                              ~keeper_id
                              ~file_path
                              ~line
                              ?column
                              ~partition
                              ?focus_mode
                              ~source
                              ()
                          with
                          | Ok () ->
                            Http.Response.json_value
                              ~status:`Created
                              ~request
                              (json_ok (`Assoc [ "ok", `Bool true ]))
                              reqd
                          | Error msg ->
                            Http.Response.json_value
                              ~status:`Internal_server_error
                              ~request
                              (json_error ~code:"observation_write_failed" msg)
                              reqd)))))
              | _ ->
                Http.Response.json_value
                  ~status:`Bad_request
                  ~request
                  (json_error "Missing required fields: file_path, line (>=1)")
                  reqd)))
      request
      reqd)
  |> Http.Router.get "/api/v1/ide/presence/stream" (fun request reqd ->
    with_public_read
      (fun state _req inner_reqd ->
         let origin = get_origin request in
         let headers =
           Httpun.Headers.of_list
             ([ "content-type", "text/event-stream"
              ; "cache-control", "no-cache"
              ; "connection", "keep-alive"
              ; "x-accel-buffering", "no"
              ]
              @ cors_headers origin)
         in
         let response = Httpun.Response.create ~headers `OK in
         let writer = Httpun.Reqd.respond_with_streaming inner_reqd response in
         let write_snapshot () =
           let snapshot_json = Yojson.Safe.to_string (build_presence_snapshot state) in
           let event = Printf.sprintf "data: %s\n\n" snapshot_json in
           Httpun.Body.Writer.write_string writer event
         in
         write_snapshot ();
         match state.Mcp_server.sw, state.Mcp_server.clock with
         | Some sw, Some clock ->
           Eio.Fiber.fork ~sw (fun () ->
             let rec loop () =
               (try
                  Eio.Time.sleep clock 30.0;
                  write_snapshot ();
                  loop ()
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  Log.Server.debug
                    "IDE presence SSE ping loop error: %s"
                    (Printexc.to_string exn));
               Httpun.Body.Writer.close writer
             in
             try loop () with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Server.error
                 "IDE presence SSE loop exited: %s"
                 (Printexc.to_string exn);
               Httpun.Body.Writer.close writer)
         | _ -> Httpun.Body.Writer.close writer)
      request
      reqd)
  |> Http.Router.get "/api/v1/ide/cursors/stream" (fun request reqd ->
    Server_auth.with_token_permission_auth
      ~permission:Masc_domain.CanReadState
      (fun state _agent_name _req inner_reqd ->
         let uri = Uri.of_string request.target in
         match parse_pagination_query ~max_limit:200 uri with
         | Error msg ->
           Http.Response.json_value
             ~status:`Bad_request
             ~request
             (json_error msg)
             inner_reqd
         | Ok (limit, offset) ->
           (match resolve_ide_scope_for_query ~state ~uri with
            | Error err -> respond_ide_error ~status:`Bad_request ~request err inner_reqd
            | Ok scope ->
              (match
                 keeper_filter_for_scope
                   ~scope
                   ~requested_keeper_id:(keeper_id_param uri)
               with
               | Error err ->
                 respond_ide_error ~status:`Bad_request ~request err inner_reqd
               | Ok keeper_id ->
              with_keeper_lane_read_auth ~state ~request ~reqd:inner_reqd ~scope (fun () ->
              let partition = partition_of_ide_scope scope in
              let origin = get_origin request in
              let headers =
                Httpun.Headers.of_list
                  ([ "content-type", "text/event-stream"
                   ; "cache-control", "no-cache"
                   ; "connection", "keep-alive"
                   ; "x-accel-buffering", "no"
                   ]
                   @ cors_headers origin)
              in
              let response = Httpun.Response.create ~headers `OK in
              let writer = Httpun.Reqd.respond_with_streaming inner_reqd response in
              let write_snapshot () =
                let snapshot_json =
                  Yojson.Safe.to_string
                    (build_cursor_snapshot state uri ~partition ~keeper_id ~limit ~offset)
                in
                let event = Printf.sprintf "data: %s\n\n" snapshot_json in
                Httpun.Body.Writer.write_string writer event
              in
              write_snapshot ();
              (match state.Mcp_server.sw, state.Mcp_server.clock with
               | Some sw, Some clock ->
                 Eio.Fiber.fork ~sw (fun () ->
                   let rec loop () =
                     (try
                        Eio.Time.sleep clock 30.0;
                        write_snapshot ();
                        loop ()
                      with
                      | Eio.Cancel.Cancelled _ as e -> raise e
                      | exn ->
                        Log.Server.debug
                          "IDE cursor SSE ping loop error: %s"
                          (Printexc.to_string exn));
                     Httpun.Body.Writer.close writer
                   in
                   try loop () with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                     Log.Server.error
                       "IDE cursor SSE loop exited: %s"
                       (Printexc.to_string exn);
                     Httpun.Body.Writer.close writer)
               | _ -> Httpun.Body.Writer.close writer)))))
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
              (match keeper_filter_for_scope ~scope ~requested_keeper_id:keeper_id with
               | Error err ->
                 respond_ide_error ~status:`Bad_request ~request err inner_reqd
               | Ok keeper_id ->
              with_keeper_lane_read_auth ~state ~request ~reqd:inner_reqd ~scope (fun () ->
              let partition = partition_of_ide_scope scope in
              let filter : Ide_annotation_types.annotation_filter =
                { file_path = None; keeper_id; goal_id = None; task_id = None }
              in
              let annotations = Ide_annotations.list ~base_dir:base ~partition ~filter () in
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
              Httpun.Reqd.respond_with_string inner_reqd response body))))
      request
      reqd)
;;
