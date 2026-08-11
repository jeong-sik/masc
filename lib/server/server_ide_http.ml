(** Server IDE HTTP — REST endpoints for observational IDE annotations
    and code regions.

    Reads/writes are scoped to the workspace base resolved by
    {!Server_routes_http_routes_workspace.classify_workspace_query}. *)

open Server_auth
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

let nonempty_query_param uri key =
  match Uri.get_query_param uri key with
  | Some raw ->
    let value = String.trim raw in
    if String.equal value "" then None else Some value
  | None -> None
;;

type ide_scope =
  | Scope_default
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
  | Scope_keeper_lane _ | Scope_default -> Ide_paths.Legacy_default
;;

let resolve_ide_scope_for_query ~state ~uri =
  let project_base = base_path_of_state state in
  let scope_from_repo_id =
    match nonempty_query_param uri "repo_id" with
    | None -> None
    | Some repo_id ->
      (match Repo_store.find_url_by_id ~base_path:project_base repo_id with
       | Ok (Some url) ->
         (match Ide_paths.canonical_url_of_remote url with
          | Some slug -> Some (Scope_repo_id { repo_id; slug })
          | None -> None)
       | Error _ | Ok None -> None)
  in
  let scope_from_canonical_url =
    match nonempty_query_param uri "canonical_url" with
    | Some raw ->
      (match Ide_paths.canonical_url_of_remote raw with
       | Some slug -> Some (Scope_canonical_url { raw; slug })
       | None -> None)
    | None -> None
  in
  let scope =
    match scope_from_repo_id, scope_from_canonical_url, nonempty_query_param uri "keeper_lane" with
    | Some scope, _, _ -> scope
    | None, Some scope, _ -> scope
    | None, None, Some keeper_id -> Scope_keeper_lane { keeper_id }
    | None, None, None -> Scope_default
  in
  Ok scope
;;

(* Writes share the public feature lane. Repository selection is not a
   prerequisite for using the IDE: missing, stale, or keeper-lane scope writes
   go to the same default lane the public read flow exposes. *)
let resolve_partition_for_mutation ~state ~uri =
  match resolve_ide_scope_for_query ~state ~uri with
  | Ok scope -> Ok (partition_of_ide_scope scope)
  | Error _ as err -> err
;;

(* A lane supplies the keeper filter when the caller did not supply one.
   An explicit keeper filter wins so a stale lane selection cannot block the
   observation view from showing the requested keeper. *)
let keeper_filter_for_scope ~scope ~requested_keeper_id =
  match scope with
  | Scope_keeper_lane { keeper_id = lane } ->
    let keeper_id =
      match requested_keeper_id with
      | Some keeper_id -> keeper_id
      | None -> lane
    in
    Ok (Some keeper_id)
  | Scope_default | Scope_canonical_url _ | Scope_repo_id _ -> Ok requested_keeper_id
;;

let partition_from_annotation_file_path ~state ~file_path =
  if Filename.is_relative file_path then None
  else
    match
      Repo_store.find_repo_by_path_prefix
        ~base_path:(base_path_of_state state)
        file_path
    with
    | Ok (Some (repo, _)) ->
      (match Ide_paths.canonical_url_of_remote repo.url with
       | Some slug -> Some (Ide_paths.By_url slug)
       | None -> None)
    | Error _ | Ok None -> None
;;

let resolve_partition_for_annotation_post ~state ~uri ~file_path =
  (* A file path is stronger evidence than a concurrently stale repo picker.
     Use its repository partition when known; otherwise preserve the selected
     (or default) lane instead of rejecting a valid IDE write. *)
  match partition_from_annotation_file_path ~state ~file_path with
  | Some partition -> Ok partition
  | None -> resolve_partition_for_mutation ~state ~uri
;;

let ide_memory_source_kind = "ide_annotation"
let ide_memory_retrieval_status = "annotation_index_only"
let ide_memory_semantic_status = "not_configured"
let ide_memory_episodic_status = "not_configured"

let json_ok data = `Assoc [ "ok", `Bool true; "data", data ]

(* ── Public IDE mutation helpers ───────────────────────────────────── *)

(* Cursor observations remain a public projection and use a stable identity
   when no authenticated identity is available. Annotation writes do not use
   this helper: their author must come from the token-bound identity. *)
let default_public_mutation_keeper_id = "dashboard"

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

let public_mutation_keeper_id json =
  match json_string_field "keeper_id" json with
  | Some keeper_id -> keeper_id
  | None -> default_public_mutation_keeper_id
;;

let annotation_keeper_id_not_accepted_error =
  "keeper_id is not accepted; identity is derived from the authentication token"
;;

let annotation_delete_rejected_error = "annotation delete rejected"
let annotation_delete_rejected_code = "annotation_delete_rejected"

let bind_annotation_keeper_id ~auth_identity ~requested =
  match requested with
  | None -> Ok auth_identity
  | Some _ -> Error annotation_keeper_id_not_accepted_error
;;

(* Cursor writes still use the public projection's compatibility identity.
   Annotation routes call [bind_annotation_keeper_id] instead. *)
let bind_mutation_keeper_id ~auth_identity:_ ~requested =
  match requested with
  | Some keeper_id -> Ok keeper_id
  | None -> Ok default_public_mutation_keeper_id
;;

let log_keeper_id_not_accepted ~operation ~auth_identity ~requested =
  Log.Server.warn
    "IDE annotation %s rejected client-supplied keeper_id: requested_keeper_id=%S auth_identity=%S"
    operation
    requested
    auth_identity
;;

let log_annotation_delete_rejected ~auth_identity ~id ~reason =
  Log.Server.warn
    "IDE annotation delete rejected: id=%s auth_identity=%S reason=%s"
    id
    auth_identity
    reason
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

(* Annotation [kind] parsing is sound-partial. An
   absent field defaults to the neutral [Comment] kind (backward
   compatible with clients that omit [kind]); an unrecognized value is
   rejected with a typed error rather than silently coerced to a default. *)
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

(* The IDE shell can reach the server through either the HTTP/1 router or the
   h2c gateway.  Keep the observable read projection here, above the transport
   adapters, so both paths use the same default-lane fallback and response
   shape. Mutations use a separate body-bearing projection below. *)
type public_read_response =
  { status : [ `OK | `Bad_request ]
  ; body : Yojson.Safe.t
  ; extra_headers : (string * string) list
  ; use_public_cors : bool
  ; compress : bool
  }

let public_read_ok ?(extra_headers = []) ?(use_public_cors = false)
    ?(compress = true) body =
  { status = `OK; body; extra_headers; use_public_cors; compress }
;;

let public_read_bad_request ?(extra_headers = []) ?(use_public_cors = false)
    ?(compress = true) body =
  { status = `Bad_request; body; extra_headers; use_public_cors; compress }
;;

let observation_snapshot_public_read_response request =
  let uri = Uri.of_string request.Httpun.Request.target in
  let take =
    match Uri.get_query_param uri "take" with
    | Some "true" -> true
    | _ -> false
  in
  let json = Ide_bridge.observation_snapshot_json ~take in
  public_read_ok
    ~extra_headers:[ "x-observation-mode", if take then "take" else "peek" ]
    (json_ok json)
;;

let agents_read_response state =
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
  public_read_ok (json_ok (`Assoc [ "agents", `List entries ]))
;;

let status_read_response state =
  let config = Mcp_server.workspace_config state in
  let workspace_state = Workspace.read_state config in
  let tempo = Tempo.get_tempo config in
  let json =
    `Assoc
      [ "cluster", `String (Env_config_core.cluster_name ())
      ; "project", `String workspace_state.project
      ; "tempo_interval_s", `Float tempo.current_interval_s
      ; "paused", `Bool workspace_state.paused
      ]
  in
  public_read_ok (json_ok json)
;;

let annotations_read_response ~state ~uri =
  (* RFC-0128 §4.2 PR-8: partition storage lives under the server base path
     (one .masc-ide tree), not a browsed workspace tree. *)
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
  | Error err -> public_read_bad_request (json_error ~code:err.code err.message)
  | Ok scope ->
    (match keeper_filter_for_scope ~scope ~requested_keeper_id:keeper_id with
     | Error err -> public_read_bad_request (json_error ~code:err.code err.message)
     | Ok keeper_id ->
       let partition = partition_of_ide_scope scope in
       let filter =
         { Ide_annotation_types.file_path; keeper_id; goal_id; task_id }
       in
       let annotations = Ide_annotations.list ~base_dir:base ~partition ~filter () in
       let json = `List (List.map Ide_annotation_types.annotation_to_json annotations) in
       public_read_ok (json_ok json))
;;

let regions_read_response ~state ~uri =
  (* See [annotations_read_response] for why the server base owns this
     partition, even when a client currently has no repository selected. *)
  let base = base_path_of_state state in
  let file_path =
    match Uri.get_query_param uri "file_path" with
    | Some p when p <> "" -> Some p
    | _ -> None
  in
  match resolve_ide_scope_for_query ~state ~uri with
  | Error err -> public_read_bad_request (json_error ~code:err.code err.message)
  | Ok scope ->
    let partition = partition_of_ide_scope scope in
    let regions =
      Ide_region_tracker.read_regions ~base_dir:base ~partition ?file_path ()
    in
    let regions =
      match scope with
      | Scope_keeper_lane { keeper_id } ->
        List.filter
          (fun (region : Ide_annotation_types.code_region) ->
             String.equal region.keeper_id keeper_id)
          regions
      | Scope_default | Scope_canonical_url _ | Scope_repo_id _ -> regions
    in
    let json = `List (List.map Ide_annotation_types.region_to_json regions) in
    public_read_ok (json_ok json)
;;

let events_read_response ~state ~uri =
  match event_kind_param uri with
  | Error msg -> public_read_bad_request (json_error msg)
  | Ok kind ->
    (match parse_pagination_query ~max_limit:200 uri with
     | Error msg -> public_read_bad_request (json_error msg)
     | Ok (limit, offset) ->
       let base = base_path_of_state state in
       (match resolve_ide_scope_for_query ~state ~uri with
        | Error err -> public_read_bad_request (json_error ~code:err.code err.message)
        | Ok scope ->
          (match
             keeper_filter_for_scope ~scope ~requested_keeper_id:(keeper_id_param uri)
           with
           | Error err ->
             public_read_bad_request (json_error ~code:err.code err.message)
           | Ok keeper_id ->
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
               | Some kind -> `String (Ide_bridge.event_kind_to_string kind)
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
             public_read_ok (json_ok result))))
;;

let presence_read_response state =
  public_read_ok (json_ok (build_presence_snapshot state))
;;

let cursors_read_response ~state ~uri =
  match parse_pagination_query ~max_limit:200 uri with
  | Error msg -> public_read_bad_request (json_error msg)
  | Ok (limit, offset) ->
    (match resolve_ide_scope_for_query ~state ~uri with
     | Error err -> public_read_bad_request (json_error ~code:err.code err.message)
     | Ok scope ->
       (match keeper_filter_for_scope ~scope ~requested_keeper_id:(keeper_id_param uri) with
        | Error err -> public_read_bad_request (json_error ~code:err.code err.message)
        | Ok keeper_id ->
          let partition = partition_of_ide_scope scope in
          let snapshot =
            build_cursor_snapshot state uri ~partition ~keeper_id ~limit ~offset
          in
          public_read_ok (json_ok snapshot)))
;;

let memory_read_response ~state ~uri =
  let base = base_path_of_state state in
  let keeper_id =
    match Uri.get_query_param uri "keeper_id" with
    | Some keeper_id when keeper_id <> "" -> Some keeper_id
    | _ -> None
  in
  match parse_positive_int_query uri "limit" with
  | Error msg -> public_read_bad_request (json_error msg)
  | Ok limit ->
    (* Memory tiers are annotation-index backed for now; the response makes
       that explicit rather than pretending a semantic index exists. *)
    (match resolve_ide_scope_for_query ~state ~uri with
     | Error err ->
       public_read_bad_request (json_error ~code:err.code err.message)
     | Ok scope ->
       (match keeper_filter_for_scope ~scope ~requested_keeper_id:keeper_id with
        | Error err ->
          public_read_bad_request (json_error ~code:err.code err.message)
        | Ok keeper_id ->
          let partition = partition_of_ide_scope scope in
          let filter : Ide_annotation_types.annotation_filter =
            { file_path = None; keeper_id; goal_id = None; task_id = None }
          in
          let annotations = Ide_annotations.list ~base_dir:base ~partition ~filter () in
          let entries =
            List.map
              (fun (annotation : Ide_annotation_types.annotation) ->
                 `Assoc
                   [ "id", `String annotation.id
                   ; "kind", `String (Ide_annotation_types.annotation_kind_to_string annotation.kind)
                   ; "content", `String annotation.content
                   ; "file_path", `String annotation.file_path
                   ; "line_start", `Int annotation.line_start
                   ; "line_end", `Int annotation.line_end
                   ; "keeper_id", `String annotation.keeper_id
                   ; "created_at_ms", `Intlit (Int64.to_string annotation.created_at_ms)
                   ; "source_kind", `String ide_memory_source_kind
                   ; "retrieval_status", `String ide_memory_retrieval_status
                   ; "goal_id", (match annotation.goal_id with Some goal_id -> `String goal_id | None -> `Null)
                   ; "task_id", (match annotation.task_id with Some task_id -> `String task_id | None -> `Null)
                   ])
              (List.filteri (fun index _ -> index < limit) annotations)
          in
          let result =
            `Assoc
              [ "entries", `List entries
              ; "total", `Int (List.length annotations)
              ; "limit", `Int limit
              ; ( "contract"
                , `Assoc
                    [ "source_kind", `String ide_memory_source_kind
                    ; "retrieval_status", `String ide_memory_retrieval_status
                    ; "semantic_memory_status", `String ide_memory_semantic_status
                    ; "episodic_memory_status", `String ide_memory_episodic_status
                    ] )
              ]
          in
          public_read_ok ~use_public_cors:true ~compress:false result))
;;

let public_read_response ~state request =
  let path = Http.Request.path request in
  let uri = Uri.of_string request.Httpun.Request.target in
  match path with
  | "/api/v1/ide/observations/snapshot" ->
    Some (observation_snapshot_public_read_response request)
  | "/api/v1/agents" -> Some (agents_read_response state)
  | "/api/v1/status" -> Some (status_read_response state)
  | "/api/v1/ide/annotations" -> Some (annotations_read_response ~state ~uri)
  | "/api/v1/ide/regions" -> Some (regions_read_response ~state ~uri)
  | "/api/v1/ide/events" -> Some (events_read_response ~state ~uri)
  | "/api/v1/ide/presence" -> Some (presence_read_response state)
  | "/api/v1/ide/cursors" -> Some (cursors_read_response ~state ~uri)
  | "/api/v1/ide/memory" -> Some (memory_read_response ~state ~uri)
  | _ -> None
;;

(* Keep the annotation write projection independent of HTTP/1 request
   bodies while requiring the caller's token-bound identity.  The h2c
   transport supplies that identity after the same permission check as H1. *)
type public_mutation_response =
  { status : [ `Created | `No_content | `Bad_request | `Forbidden | `Internal_server_error ]
  ; body : Yojson.Safe.t option
  }

let public_mutation_json ?(status = `Created) body =
  { status; body = Some body }
;;

let public_mutation_empty = { status = `No_content; body = None }

let public_annotation_create_response ~state ~auth_identity ~request ~body =
  let uri = Uri.of_string request.Httpun.Request.target in
  let base = base_path_of_state state in
  match parse_json_body body with
  | Error msg -> public_mutation_json ~status:`Bad_request (json_error msg)
  | Ok json ->
    (match validate_annotation_post_fields json with
     | Error msg ->
       public_mutation_json
         ~status:`Bad_request
         (json_error ~code:"invalid_annotation_request" msg)
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
         (match parse_annotation_kind (find_string "kind") with
          | Error msg -> public_mutation_json ~status:`Bad_request (json_error msg)
          | Ok kind ->
            let requested_keeper_id = find_string "keeper_id" in
            (match
               bind_annotation_keeper_id
                 ~auth_identity
                 ~requested:requested_keeper_id
             with
             | Error msg ->
               Option.iter
                 (fun requested ->
                    log_keeper_id_not_accepted
                      ~operation:"create"
                      ~auth_identity
                      ~requested)
                 requested_keeper_id;
               public_mutation_json
                 ~status:`Forbidden
                 (json_error msg)
             | Ok keeper_id ->
               let goal_id = find_string "goal_id" in
               let task_id = find_string "task_id" in
            let references_json = Yojson.Safe.Util.member "references" json in
            (match Ide_annotation_types.annotation_references_of_json references_json with
             | Error msg ->
               public_mutation_json
                 ~status:`Bad_request
                 (json_error ~code:"invalid_references" msg)
             | Ok references ->
               (match resolve_partition_for_annotation_post ~state ~uri ~file_path with
                | Error err ->
                  public_mutation_json
                    ~status:`Bad_request
                    (json_error ~code:err.code err.message)
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
                       ~references
                       ()
                   with
                   | Ok annotation ->
                     public_mutation_json
                       (json_ok (Ide_annotation_types.annotation_to_json annotation))
                   | Error msg ->
                     public_mutation_json
                       ~status:`Bad_request
                       (json_error ~code:"observation_write_failed" msg))))))
       | _ -> public_mutation_json ~status:`Bad_request (json_error "Missing required fields"))
;;

let public_annotation_delete_response ~state ~auth_identity ~request =
  let uri = Uri.of_string request.Httpun.Request.target in
  let base = base_path_of_state state in
  let id =
    match extract_path_param ~prefix:"/api/v1/ide/annotations/" (Http.Request.path request) with
    | Some id when id <> "" -> id
    | None | Some _ -> ""
  in
  if String.equal id ""
  then public_mutation_json ~status:`Bad_request (json_error "Missing id")
  else
    match resolve_partition_for_mutation ~state ~uri with
    | Error err ->
      public_mutation_json ~status:`Bad_request (json_error ~code:err.code err.message)
    | Ok partition ->
      let requested_keeper_id =
        match Uri.get_query_param uri "keeper_id" with
        | Some keeper_id when String.trim keeper_id <> "" -> Some (String.trim keeper_id)
        | _ -> None
      in
      (match
         bind_annotation_keeper_id
           ~auth_identity
           ~requested:requested_keeper_id
       with
       | Error msg ->
         Option.iter
           (fun requested ->
              log_keeper_id_not_accepted
                ~operation:"delete"
                ~auth_identity
                ~requested)
           requested_keeper_id;
         public_mutation_json
           ~status:`Forbidden
           (json_error
              ~code:"keeper_id_not_accepted"
              msg)
       | Ok keeper_id ->
         (match
            Ide_annotations.delete
              ~base_dir:base
              ~partition
              ~id
              ~keeper_id
              ()
          with
          | Ok () -> public_mutation_empty
          | Error msg ->
            log_annotation_delete_rejected ~auth_identity ~id ~reason:msg;
            public_mutation_json
              ~status:`Forbidden
              (json_error
                 ~code:annotation_delete_rejected_code
                 annotation_delete_rejected_error)))
;;

let public_cursor_create_response ~state ~request ~body =
  let base = base_path_of_state state in
  let uri = Uri.of_string request.Httpun.Request.target in
  match parse_json_body body with
  | Error msg -> public_mutation_json ~status:`Bad_request (json_error msg)
  | Ok json ->
    let find_string key = json_string_field key json in
    let find_int key = json_int_field key json in
    (match find_string "file_path", find_int "line" with
     | Some file_path, Some line when line >= 1 ->
       let column = find_int "column" in
       (match column with
        | Some value when value < 0 ->
          public_mutation_json ~status:`Bad_request (json_error "column must be >= 0")
        | None | Some _ ->
          let source =
            match find_string "source" with
            | Some source -> source
            | None -> "editor"
          in
          (match cursor_focus_mode_field json with
           | Error msg ->
             public_mutation_json
               ~status:`Bad_request
               (json_error ~code:"invalid_focus_mode" msg)
           | Ok focus_mode ->
             let keeper_id = public_mutation_keeper_id json in
             (match resolve_partition_for_annotation_post ~state ~uri ~file_path with
              | Error err ->
                public_mutation_json
                  ~status:`Bad_request
                  (json_error ~code:err.code err.message)
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
                 | Ok () -> public_mutation_json (json_ok (`Assoc [ "ok", `Bool true ]))
                 | Error msg ->
                   public_mutation_json
                     ~status:`Internal_server_error
                     (json_error ~code:"observation_write_failed" msg)))))
     | None, _ | Some _, None | Some _, Some _ ->
       public_mutation_json
         ~status:`Bad_request
         (json_error "Missing required fields: file_path, line (>=1)"))
;;

let respond_public_read_response ~request reqd response =
  let extra_headers =
    if response.use_public_cors
    then cors_headers (get_origin request) @ response.extra_headers
    else response.extra_headers
  in
  match response.status with
  | `OK ->
    Http.Response.json_value
      ~compress:response.compress
      ~request
      ~extra_headers
      response.body
      reqd
  | `Bad_request ->
    Http.Response.json_value
      ~status:`Bad_request
      ~compress:response.compress
      ~request
      ~extra_headers
      response.body
      reqd
;;

let respond_public_mutation_response ~request reqd response =
  match response.status, response.body with
  | `No_content, _ -> Http.Response.empty ~status:`No_content reqd
  | (`Created | `Bad_request | `Forbidden | `Internal_server_error as status), Some body ->
    Http.Response.json_value
      ~status
      ~request
      ~extra_headers:(public_read_cors_headers request)
      body
      reqd
  | (`Created | `Bad_request | `Forbidden | `Internal_server_error), None ->
    Http.Response.empty ~status:`Internal_server_error reqd
;;

let public_read_handler request reqd =
  with_public_read
    (fun state _request inner_reqd ->
       match public_read_response ~state request with
       | Some response -> respond_public_read_response ~request inner_reqd response
       | None -> Http.Response.not_found inner_reqd)
    request
    reqd
;;

let observation_snapshot_handler request reqd =
  respond_public_read_response
    ~request
    reqd
    (observation_snapshot_public_read_response request)
;;

let add_routes router =
  Ide_bridge.register_cursor_changed_sink (fun ~keeper_id ->
    Sse.broadcast
      (`Assoc
         [ "type", `String "ide_cursor_changed"
         ; "keeper_id", `String keeper_id
         ]));
  Ide_bridge.install_agent_observation_sinks ();
  router
  |> Http.Router.get "/api/v1/ide/observations/snapshot" observation_snapshot_handler
  |> Http.Router.get "/api/v1/agents" public_read_handler
  |> Http.Router.get "/api/v1/status" public_read_handler
  |> Http.Router.get "/api/v1/ide/annotations" public_read_handler
  |> Http.Router.post "/api/v1/ide/annotations" (fun request reqd ->
    (* Annotation authorship is token-bound; the request body may not
       select another keeper. *)
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
               (* A caller-provided keeper id is checked against the
                  token-bound identity before durable creation. *)
               let requested_keeper_id = find_string "keeper_id" in
               (match
                  bind_annotation_keeper_id ~auth_identity ~requested:requested_keeper_id
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
    (* Annotation deletion is authorized against the token-bound owner. *)
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
             bind_annotation_keeper_id ~auth_identity ~requested:requested_keeper_id
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
                   Ide_annotations.delete
                     ~base_dir:base
                     ~partition
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
  |> Http.Router.get "/api/v1/ide/regions" public_read_handler
  |> Http.Router.get "/api/v1/ide/events" public_read_handler
  |> Http.Router.get "/api/v1/ide/presence" public_read_handler
  |> Http.Router.get "/api/v1/ide/cursors" public_read_handler
  |> Http.Router.post "/api/v1/ide/cursors" (fun request reqd ->
    (* Public feature lane: a cursor is live observation data, so publish it
       even when browser identity/bootstrap has not completed. *)
    with_public_read
      (fun state _req reqd ->
         let auth_identity = default_public_mutation_keeper_id in
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
                      (* Resolve the write partition from the posted [file_path]
                         rather than URI query params alone, so a stale picker
                         cannot misplace a cursor update. *)
                      (match resolve_partition_for_annotation_post ~state ~uri ~file_path with
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
  |> Http.Router.get "/api/v1/ide/memory" public_read_handler
;;
