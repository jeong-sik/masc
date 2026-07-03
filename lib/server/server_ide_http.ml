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

(* RFC-0128 §4.5 — resolve the partition for a query.

   Priority:
     1. [?canonical_url=...] explicit override (still re-normalised so a
        misspelt query falls back to Orphan rather than silently
        creating a new bucket).
     2. [?repo_id=...] → lookup repo.url in [Repo_store] → normalise.
     3. Default → [Orphan] so traffic that has not been updated to use
        either parameter is preserved in the unresolved partition.

   PR-1d removed the old [Legacy] constructor in favor of [Orphan]. *)
let resolve_partition_for_query ~state ~uri =
  let project_base = base_path_of_state state in
  let from_canonical =
    match Uri.get_query_param uri "canonical_url" with
    | Some s when String.trim s <> "" -> Ide_paths.canonical_url_of_remote s
    | _ -> None
  in
  let from_repo_id () =
    match Uri.get_query_param uri "repo_id" with
    | Some id when String.trim id <> "" ->
      (match Repo_store.find_url_by_id ~base_path:project_base id with
       | Some url -> Ide_paths.canonical_url_of_remote url
       | None -> None)
    | _ -> None
  in
  match from_canonical with
  | Some slug -> Ide_paths.By_url slug
  | None ->
    (match from_repo_id () with
     | Some slug -> Ide_paths.By_url slug
     | None -> Ide_paths.Orphan)
;;

let json_error message = `Assoc [ "ok", `Bool false; "error", `String message ]
let json_ok data = `Assoc [ "ok", `Bool true; "data", data ]
let keeper_id_mismatch_error = "keeper_id does not match authenticated identity"

let parse_json_body body_str =
  match Yojson.Safe.from_string body_str with
  | json -> Ok json
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
;;

let log_keeper_id_mismatch ~operation ~auth_identity ~requested =
  Log.Server.warn
    "IDE annotation %s rejected keeper_id mismatch: requested_keeper_id=%S \
     auth_identity=%S"
    operation
    requested
    auth_identity
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
   param). It is advisory only:
     - absent / blank  -> use the authenticated identity
     - equal           -> use the authenticated identity (explicit, allowed)
     - differs         -> reject as an impersonation attempt

   Rejecting (rather than silently overriding) a mismatch keeps a buggy
   or malicious client from believing it wrote as some other keeper. *)
let bind_mutation_keeper_id ~auth_identity ~requested :
  (string, string) result =
  match requested with
  | None -> Ok auth_identity
  | Some raw ->
    let requested = String.trim raw in
    if requested = "" || String.equal requested auth_identity
    then Ok auth_identity
    else Error keeper_id_mismatch_error
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

let parse_positive_int_query ?(default = 50) ?(max_value = 200) uri name =
  match Uri.get_query_param uri name with
  | Some s ->
    (match int_of_string_opt s with
     | Some n when n > 0 -> min n max_value
     | _ -> default)
  | None -> default
;;

let parse_non_negative_int_query ?(default = 0) uri name =
  match Uri.get_query_param uri name with
  | Some s ->
    (match int_of_string_opt s with
     | Some n when n > 0 -> n
     | _ -> default)
  | None -> default
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

let build_cursor_snapshot state uri =
  let base = base_path_of_state state in
  let runtime_id, branch = runtime_id_and_branch state in
  let partition = resolve_partition_for_query ~state ~uri in
  let keeper_id = keeper_id_param uri in
  let file_path = file_path_param uri in
  let limit = parse_positive_int_query ~default:50 ~max_value:200 uri "limit" in
  let offset = parse_non_negative_int_query ~default:0 uri "offset" in
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
         let filter = { Ide_annotation_types.file_path; keeper_id; goal_id; task_id } in
         let partition = resolve_partition_for_query ~state ~uri in
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
           reqd)
      request
      reqd)
  |> Http.Router.post "/api/v1/ide/annotations" (fun request reqd ->
    (* task-1736 B3: annotation creation is a mutation. It requires a
       token-bound write identity ([CanBroadcast], the keeper write
       tier; no narrower annotation-write permission exists yet) instead
       of [with_public_read], and the acting keeper is the resolved
       [auth_identity] rather than a caller-chosen field. *)
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
             let find_string key =
               match json with
               | `Assoc fields ->
                 (match List.assoc_opt key fields with
                  | Some (`String s) when s <> "" -> Some s
                  | _ -> None)
               | _ -> None
             in
             let find_int key =
               match json with
               | `Assoc fields ->
                 (match List.assoc_opt key fields with
                  | Some (`Int i) -> Some i
                  | Some (`Intlit s) -> int_of_string_opt s
                  | _ -> None)
               | _ -> None
             in
             match
               ( find_string "file_path"
               , find_int "line_start"
               , find_int "line_end"
               , find_string "content" )
             with
             | Some file_path, Some line_start, Some line_end, Some content ->
               (* task-1736 B3: keeper_id is bound to the authenticated
                  identity. A body-supplied keeper_id is advisory and must
                  match, otherwise the create is rejected as impersonation. *)
               let requested_keeper_id = find_string "keeper_id" in
               (match
                  bind_mutation_keeper_id ~auth_identity ~requested:requested_keeper_id
                with
                | Error msg ->
                  Option.iter
                    (fun requested ->
                       log_keeper_id_mismatch
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
                     let partition = resolve_partition_for_query ~state ~uri in
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
                          (json_error msg)
                          reqd)))
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
       annotation-write permission exists yet) instead of [with_public_read],
       and ownership is enforced against the resolved [auth_identity] rather
       than a caller-supplied query param. Because [Ide_annotations.delete]
       only removes an annotation whose stored keeper_id equals the passed
       keeper_id, binding keeper_id to auth_identity makes it structurally
       impossible to delete another keeper's annotation. *)
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
                  log_keeper_id_mismatch
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
             let partition = resolve_partition_for_query ~state ~uri in
             (match
                Ide_annotations.delete ~base_dir:base ~partition ~id ~keeper_id ()
              with
              | Ok () -> Http.Response.empty ~status:`No_content reqd
              | Error msg ->
                Http.Response.json_value
                  ~status:`Forbidden
                  ~request
                  (json_error msg)
                  reqd))
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
         let partition = resolve_partition_for_query ~state ~uri in
         let regions =
           Ide_region_tracker.read_regions
             ~base_dir:base
             ~partition
             ?file_path
             ()
         in
         let json = `List (List.map Ide_annotation_types.region_to_json regions) in
         Http.Response.json_value
           ~compress:true
           ~request
           (json_ok json)
           reqd)
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
           let base = base_path_of_state state in
           let partition = resolve_partition_for_query ~state ~uri in
           let keeper_id = keeper_id_param uri in
           let limit = parse_positive_int_query ~default:50 ~max_value:200 uri "limit" in
           let offset = parse_non_negative_int_query ~default:0 uri "offset" in
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
             reqd)
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
         let snapshot = build_cursor_snapshot state uri in
         Http.Response.json_value
           ~compress:true
           ~request
           (json_ok snapshot)
           reqd)
      request
      reqd)
  |> Http.Router.post "/api/v1/ide/cursors" (fun request reqd ->
    with_public_read
      (fun state req reqd ->
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
             let find_string key =
               match json with
               | `Assoc fields ->
                 (match List.assoc_opt key fields with
                  | Some (`String s) when s <> "" -> Some s
                  | _ -> None)
               | _ -> None
             in
             let find_int key =
               match json with
               | `Assoc fields ->
                 (match List.assoc_opt key fields with
                  | Some (`Int i) -> Some i
                  | Some (`Intlit s) -> int_of_string_opt s
                  | _ -> None)
               | _ -> None
             in
             match
               ( find_string "file_path"
               , find_int "line"
               , find_string "keeper_id" )
             with
             | Some file_path, Some line, Some keeper_id
               when line >= 1 ->
               let column = find_int "column" in
               let source = Option.value (find_string "source") ~default:"editor" in
               Ide_bridge.ingest_cursor_event
                 ~base_path:base
                 ~keeper_id
                 ~file_path
                 ~line
                 ?column
                 ~source
                 ();
               Http.Response.json_value
                 ~status:`Created
                 ~request
                 (json_ok (`Assoc [ "ok", `Bool true ]))
                 reqd
             | _ ->
               Http.Response.json_value
                 ~status:`Bad_request
                 ~request
                 (json_error "Missing required fields: file_path, line (>=1), keeper_id")
                 reqd))
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
    with_public_read
      (fun state _req inner_reqd ->
         let uri = Uri.of_string request.target in
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
             Yojson.Safe.to_string (build_cursor_snapshot state uri)
           in
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
         | _ -> Httpun.Body.Writer.close writer)
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
         let limit =
           match Uri.get_query_param uri "limit" with
           | Some s -> (try int_of_string s with _ -> 50)
           | None -> 50
         in
         (* Memory tiers: retrospective, episode, semantic.
            Currently returns annotation-based memory entries.
            Future: integrate with Neo4j/pgvector for semantic search. *)
         let filter : Ide_annotation_types.annotation_filter =
           { file_path = None; keeper_id; goal_id = None; task_id = None }
         in
         let annotations = Ide_annotations.list ~base_dir:base ~filter () in
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
               ("goal_id", (match a.goal_id with Some g -> `String g | None -> `Null));
               ("task_id", (match a.task_id with Some t -> `String t | None -> `Null));
             ])
           (List.filteri (fun i _ -> i < limit) annotations)
         in
         let result = `Assoc [
           ("entries", `List entries);
           ("total", `Int (List.length annotations));
           ("limit", `Int limit);
         ] in
         let origin = get_origin request in
         let headers =
           Httpun.Headers.of_list
             (("content-type", "application/json") :: cors_headers origin)
         in
         let body = Yojson.Safe.to_string result in
         let response = Httpun.Response.create ~headers `OK in
         Httpun.Reqd.respond_with_string inner_reqd response body)
      request
      reqd)
;;

module For_testing = struct
  let bind_mutation_keeper_id = bind_mutation_keeper_id
  let parse_annotation_kind = parse_annotation_kind
end
