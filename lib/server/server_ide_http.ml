(** Server IDE HTTP — REST endpoints for observational IDE annotations
    and code regions.

    Reads/writes are scoped to the workspace base resolved by
    {!Server_routes_http_routes_workspace.classify_workspace_query}. *)

open Server_auth
open Server_utils
module Http = Http_server_eio

let base_path_of_state state = state.Mcp_server.room_config.base_path
let extract_path_param = Server_utils.extract_path_param

let resolve_workspace_base ~state ~uri =
  let project_base = base_path_of_state state in
  let config = state.Mcp_server.room_config in
  let lookup_repository repo_id =
    match Repo_store.find ~base_path:project_base repo_id with
    | Ok repo -> Some (Repo_store.local_path ~base_path:project_base repo)
    | Error _ -> None
  in
  let lookup_playground name =
    match Keeper_types.read_meta config name with
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

let json_error message = `Assoc [ "ok", `Bool false; "error", `String message ]
let json_ok data = `Assoc [ "ok", `Bool true; "data", data ]

let build_presence_snapshot state =
  let base = base_path_of_state state in
  let runtime_id =
    let base_name = Filename.basename base in
    if base_name = "" then "masc-runtime" else base_name
  in
  let branch =
    let head_path = Filename.concat base ".git/HEAD" in
    if Sys.file_exists head_path
    then (
      let ref_line =
        let ic = open_in head_path in
        let line = input_line ic in
        close_in ic;
        line
      in
      if String.starts_with ~prefix:"ref: refs/heads/" ref_line
      then String.sub ref_line 16 (String.length ref_line - 16)
      else ref_line)
    else "main"
  in
  let entries =
    let agents = Agent_registry_eio.list_active ~within_seconds:300.0 () in
    List.map
      (fun (a : Agent_identity.t) ->
         `Assoc
           [ "keeper_id", `String a.Agent_identity.agent_name
           ; "workspace_label", `String (Filename.basename base)
           ; "branch", `String branch
           ; "role", `String "keeper"
           ; "status", `String "active"
           ; ( "last_seen_ms"
             , `Intlit (Printf.sprintf "%.0f" (a.Agent_identity.registered_at *. 1000.0))
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

let add_routes router =
  router
  |> Http.Router.get "/api/v1/ide/annotations" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         let base, _source = resolve_workspace_base ~state ~uri in
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
         let annotations = Ide_annotations.list ~base_dir:base ~filter in
         let json =
           `List (List.map Ide_annotation_types.annotation_to_json annotations)
         in
         Http.Response.json
           ~compress:true
           ~request
           (Yojson.Safe.to_string (json_ok json))
           reqd)
      request
      reqd)
  |> Http.Router.post "/api/v1/ide/annotations" (fun request reqd ->
    with_public_read
      (fun state req reqd ->
         let uri = Uri.of_string request.target in
         let base, _source = resolve_workspace_base ~state ~uri in
         Http.Request.read_body_async reqd (fun body_str ->
           let json =
             try Yojson.Safe.from_string body_str with
             | _ -> `Assoc []
           in
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
             , find_string "keeper_id"
             , find_string "content" )
           with
           | Some file_path, Some line_start, Some line_end, Some keeper_id, Some content
             ->
             let kind_str = Option.value (find_string "kind") ~default:"Comment" in
             let kind =
               match Ide_annotations.annotation_kind_of_string kind_str with
               | Some k -> k
               | None -> Comment
             in
             let goal_id = find_string "goal_id" in
             let task_id = find_string "task_id" in
             (match
                Ide_annotations.create
                  ~base_dir:base
                  ~keeper_id
                  ~file_path
                  ~line_start
                  ~line_end
                  ~kind
                  ~content
                  ?goal_id
                  ?task_id
                  ()
              with
              | Ok annotation ->
                Http.Response.json
                  ~status:`Created
                  ~request
                  (Yojson.Safe.to_string
                     (json_ok (Ide_annotation_types.annotation_to_json annotation)))
                  reqd
              | Error msg ->
                Http.Response.json
                  ~status:`Bad_request
                  ~request
                  (Yojson.Safe.to_string (json_error msg))
                  reqd)
           | _ ->
             Http.Response.json
               ~status:`Bad_request
               ~request
               (Yojson.Safe.to_string (json_error "Missing required fields"))
               reqd))
      request
      reqd)
  |> Http.Router.any "/api/v1/ide/annotations/:id" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         let base, _source = resolve_workspace_base ~state ~uri in
         let id =
           match
             extract_path_param
               ~prefix:"/api/v1/ide/annotations/"
               (Http.Request.path request)
           with
           | Some s when s <> "" -> s
           | _ -> ""
         in
         let keeper_id =
           match Uri.get_query_param uri "keeper_id" with
           | Some k when k <> "" -> k
           | _ -> ""
         in
         if id = "" || keeper_id = ""
         then
           Http.Response.json
             ~status:`Bad_request
             ~request
             (Yojson.Safe.to_string (json_error "Missing id or keeper_id"))
             reqd
         else (
           match Ide_annotations.delete ~base_dir:base ~id ~keeper_id with
           | Ok () -> Http.Response.json ~status:`No_content ~request "{}" reqd
           | Error msg ->
             Http.Response.json
               ~status:`Forbidden
               ~request
               (Yojson.Safe.to_string (json_error msg))
               reqd))
      request
      reqd)
  |> Http.Router.get "/api/v1/ide/regions" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let uri = Uri.of_string request.target in
         let base, _source = resolve_workspace_base ~state ~uri in
         let file_path =
           match Uri.get_query_param uri "file_path" with
           | Some p when p <> "" -> p
           | _ -> ""
         in
         let store_dir = Filename.concat base ".masc-ide" in
         let path = Filename.concat store_dir "regions.jsonl" in
         (* Streaming filter — file_path filter usually drops most lines,
            and regions.jsonl grows append-only. fold_jsonl_lines avoids
            the full-list materialisation that List.filter_map needed. *)
         let regions =
           Fs_compat.fold_jsonl_lines
             ~init:[]
             ~f:(fun acc ~line_no:_ j ->
               match Ide_annotation_types.region_of_json j with
               | Ok r when file_path = "" || r.file_path = file_path -> r :: acc
               | _ -> acc)
             path
           |> List.rev
         in
         let json = `List (List.map Ide_annotation_types.region_to_json regions) in
         Http.Response.json
           ~compress:true
           ~request
           (Yojson.Safe.to_string (json_ok json))
           reqd)
      request
      reqd)
  (* [build_presence_snapshot] extracted in main — conflict resolved by taking
     main's helper call instead of our inline construction. *)
  |> Http.Router.get "/api/v1/ide/presence" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
         let snapshot = build_presence_snapshot state in
         Http.Response.json
           ~compress:true
           ~request
           (Yojson.Safe.to_string (json_ok snapshot))
           reqd)
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
;;
