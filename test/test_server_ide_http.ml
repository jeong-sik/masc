(** Black-box HTTP/router tests for [Server_ide_http].

    These tests exercise the public route table and actual response statuses
    rather than relying on private helpers. The IDE observation feature must
    work before token, keeper, or repository selection has converged. *)

open Alcotest

module Auth = Auth
module Http = Masc.Http_server_eio
module Json = Yojson.Safe.Util
module Sse = Masc.Sse
module Workspace = Masc.Workspace

let has_route meth path router =
  List.exists
    (fun (route : Http.Router.route) ->
       String.equal route.path path && List.mem meth route.methods)
    (Http.Router.routes router)
;;

let test_post_annotations_route_is_registered () =
  let router = Server_ide_http.add_routes (Http.Router.create ()) in
  check bool "POST /api/v1/ide/annotations" true
    (has_route `POST "/api/v1/ide/annotations" router)
;;

let test_delete_annotation_route_is_registered () =
  let router = Server_ide_http.add_routes (Http.Router.create ()) in
  check bool "DELETE /api/v1/ide/annotations/" true
    (has_route `DELETE "/api/v1/ide/annotations/" router)
;;

let test_post_cursors_route_is_registered () =
  let router = Server_ide_http.add_routes (Http.Router.create ()) in
  check bool "POST /api/v1/ide/cursors" true
    (has_route `POST "/api/v1/ide/cursors" router)
;;

let test_read_routes_stay_public () =
  let router = Server_ide_http.add_routes (Http.Router.create ()) in
  List.iter
    (fun path ->
       check bool ("GET " ^ path) true (has_route `GET path router))
    [ "/api/v1/ide/observations/snapshot"
    ; "/api/v1/agents"
    ; "/api/v1/status"
    ; "/api/v1/ide/annotations"
    ; "/api/v1/ide/regions"
    ; "/api/v1/ide/events"
    ; "/api/v1/ide/presence"
    ; "/api/v1/ide/cursors"
    ; "/api/v1/ide/memory"
    ]
;;

(* ── End-to-end request/response harness ─────────────────────────────── *)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_workspace f =
  let path = Filename.temp_file "masc-server-ide-http" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let masc_dir = Filename.concat path Common.masc_dirname in
  Unix.mkdir masc_dir 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let save_auth_config base_path =
  let cfg = { Masc_domain.default_auth_config with enabled = true; require_token = true } in
  Auth.save_auth_config base_path cfg
;;

let create_worker_token base_path agent_name =
  match Auth.create_token base_path ~agent_name ~role:Masc_domain.Worker with
  | Ok (raw_token, _cred) -> raw_token
  | Error e ->
    failf "create_token failed for %s: %s" agent_name (Masc_domain.masc_error_to_string e)
;;

let repository_fixture ~id ~url ~local_path : Repo_manager_types.repository =
  { id
  ; name = id
  ; url
  ; local_path
  ; aliases = []
  ; default_branch = "main"
  ; keepers = []
  ; status = Repo_manager_types.Active
  ; auto_sync = false
  ; sync_interval = 0
  ; created_at = Int64.zero
  ; updated_at = Int64.zero
  }
;;

let seed_annotation_scope_repos base_path =
  let masc_path = Filename.concat base_path "workspace/masc" in
  let agent_core_path = Filename.concat base_path "workspace/agent_core" in
  let repos =
    [ repository_fixture
        ~id:"masc"
        ~url:"https://github.com/jeong-sik/masc.git"
        ~local_path:masc_path
    ; repository_fixture
        ~id:"agent_core"
        ~url:"https://example.com/agent-core.git"
        ~local_path:agent_core_path
    ]
  in
  match Repo_store.save_all ~base_path repos with
  | Ok () -> masc_path, agent_core_path
  | Error msg -> failf "save repositories failed: %s" msg
;;

let annotation_body ~file_path =
  Yojson.Safe.to_string
    (`Assoc
       [ "file_path", `String file_path
       ; "line_start", `Int 1
       ; "line_end", `Int 2
       ; "content", `String "note"
       ])
;;

let masc_remote = "https://github.com/jeong-sik/masc.git"
let masc_scope_query = "canonical_url=" ^ Uri.pct_encode masc_remote

let scoped_ide_path path =
  let separator = if String.contains path '?' then "&" else "?" in
  path ^ separator ^ masc_scope_query
;;

let masc_partition () =
  match Ide_paths.canonical_url_of_remote masc_remote with
  | Some slug -> Ide_paths.By_url slug
  | None -> fail "test remote must produce a canonical IDE partition slug"
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some old -> Unix.putenv name old
      | None -> Unix.putenv name "")
    (fun () ->
       (match value with
        | Some next -> Unix.putenv name next
        | None -> Unix.putenv name "");
       f ())
;;

let http_request ~meth ~path ?(body = "") ?(token = None) () =
  let headers =
    [ "host", "localhost"
    ; "content-length", string_of_int (String.length body)
    ]
  in
  let headers =
    match token with
    | Some t -> ("authorization", "Bearer " ^ t) :: headers
    | None -> headers
  in
  let request =
    Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) meth path
  in
  request, body
;;

let dispatch router (request, body) =
  Eio_main.run (fun _env ->
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let feed input =
      let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length input) input in
      let rec loop off =
        let remaining = Bigstringaf.length bytes - off in
        if remaining > 0
        then (
          let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
          if consumed <= 0 then failf "httpun test feed made no progress";
          loop (off + consumed))
      in
      loop 0
    in
    let feed_eof input =
      let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length input) input in
      let rec loop off =
        let remaining = Bigstringaf.length bytes - off in
        if remaining > 0
        then (
          let consumed = Httpun.Server_connection.read_eof conn bytes ~off ~len:remaining in
          if consumed <= 0 then failf "httpun test EOF feed made no progress";
          loop (off + consumed))
      in
      loop 0
    in
    let request_head =
      Printf.sprintf
        "%s %s HTTP/1.1\r\n%s"
        (Httpun.Method.to_string request.Httpun.Request.meth)
        request.Httpun.Request.target
        (Httpun.Headers.to_string request.Httpun.Request.headers)
    in
    feed request_head;
    if not (String.equal body "") then feed_eof body;
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        List.iter
          (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               response_buf
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
          iovecs;
        let written =
          List.fold_left
            (fun acc (iov : Bigstringaf.t Httpun.IOVec.t) -> acc + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Buffer.contents response_buf)
;;

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse status from response: %S" response
;;

let check_status label expected response =
  let actual = status_of_response response in
  if actual <> expected
  then failf "%s: expected status %d, got %d; response=%S" label expected actual response
;;

let response_body response =
  let marker = "\r\n\r\n" in
  let marker_len = String.length marker in
  let response_len = String.length response in
  let rec loop i =
    if i + marker_len > response_len
    then failf "could not find response body separator in: %S" response
    else if String.equal (String.sub response i marker_len) marker
    then
      String.sub
        response
        (i + marker_len)
        (response_len - i - marker_len)
    else loop (i + 1)
  in
  loop 0
;;

let json_string_member label key json =
  match Json.member key json with
  | `String value -> value
  | other -> failf "%s: expected string member %s, got %s" label key (Yojson.Safe.to_string other)
;;

let json_list_member label key json =
  match Json.member key json with
  | `List values -> values
  | other -> failf "%s: expected list member %s, got %s" label key (Yojson.Safe.to_string other)
;;

let error_message_of_response response =
  response
  |> response_body
  |> Yojson.Safe.from_string
  |> json_string_member "error response" "error"
;;

let error_code_of_response response =
  response
  |> response_body
  |> Yojson.Safe.from_string
  |> json_string_member "error response" "code"
;;

let annotation_count router path =
  let request = http_request ~meth:`GET ~path () in
  let response = dispatch router request in
  check_status "GET annotations succeeds" 200 response;
  let json = response |> response_body |> Yojson.Safe.from_string in
  List.length (json_list_member "annotations response" "data" json)
;;

let setup_state base_path =
  save_auth_config base_path;
  let state = Masc.Mcp_server.For_testing.create_state ~base_path in
  Server_auth.For_testing.restore_server_state @@ Some state;
  state
;;

let with_ide_server f =
  with_temp_workspace (fun base_path ->
    let saved_state = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () -> Server_auth.For_testing.restore_server_state @@ saved_state)
      (fun () ->
         let state = setup_state base_path in
         let router = Server_ide_http.add_routes (Http.Router.create ()) in
         f ~base_path ~state ~router))
;;

let presence_agent ?keeper_name ?last_seen ~status name : Masc_domain.agent =
  let now = Masc_domain.now_iso () in
  let last_seen = Option.value last_seen ~default:now in
  let meta : Masc_domain.agent_meta =
    { session_id = "ide-presence:" ^ name
    ; agent_type = "test"
    ; pid = None
    ; hostname = None
    ; tty = None
    ; parent_task = None
    ; keeper_name
    ; keeper_id = None
    }
  in
  { id = None
  ; name
  ; agent_type = "test"
  ; status
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = now
  ; last_seen
  ; meta = Some meta
  }
;;

let test_presence_projects_only_canonical_keeper_identity () =
  with_ide_server (fun ~base_path:_ ~state ~router ->
    let config = Masc.Mcp_server.workspace_config state in
    ignore (Workspace.init config ~agent_name:None);
    let write_agent (agent : Masc_domain.agent) =
      let path =
        Filename.concat
          (Workspace.agents_dir config)
          (Workspace.safe_filename agent.name ^ ".json")
      in
      match Workspace.write_json_result config path (Masc_domain.agent_to_yojson agent) with
      | Ok () -> ()
      | Error message -> failf "write presence agent failed: %s" message
    in
    List.iter
      write_agent
      [ presence_agent
          ~keeper_name:"busy-keeper"
          ~last_seen:"2020-01-01T00:00:00Z"
          ~status:Masc_domain.Busy
          "runtime-busy"
      ; presence_agent ~keeper_name:"idle-keeper" ~status:Masc_domain.Listening
          "runtime-idle"
      ; presence_agent ~status:Masc_domain.Active "ordinary-agent"
      ; presence_agent ~keeper_name:"inactive-keeper" ~status:Masc_domain.Inactive
          "runtime-inactive"
      ];
    let response =
      dispatch router (http_request ~meth:`GET ~path:"/api/v1/ide/presence" ())
    in
    check_status "GET presence succeeds" 200 response;
    let entries =
      response
      |> response_body
      |> Yojson.Safe.from_string
      |> Json.member "data"
      |> json_list_member "presence response" "entries"
    in
    let entry_by_id keeper_id =
      List.find_opt
        (fun entry ->
           String.equal
             keeper_id
             (json_string_member "presence entry" "keeper_id" entry))
        entries
    in
    check int "only active keeper-owned agents are projected" 2 (List.length entries);
    let busy =
      match entry_by_id "busy-keeper" with
      | Some entry -> entry
      | None -> fail "busy keeper missing from presence"
    in
    let idle =
      match entry_by_id "idle-keeper" with
      | Some entry -> entry
      | None -> fail "idle keeper missing from presence"
    in
    check string "busy keeper is active presence" "active"
      (json_string_member "busy keeper" "status" busy);
    check string "listening keeper is idle presence" "idle"
      (json_string_member "idle keeper" "status" idle);
    check string "role is canonical keeper role" "keeper"
      (json_string_member "busy keeper" "role" busy))
;;

let test_presence_last_seen_ms_shared_projection () =
  let valid =
    presence_agent
      ~keeper_name:"ms-keeper"
      ~last_seen:"2020-01-01T00:00:00Z"
      ~status:Masc_domain.Active
      "runtime-ms"
  in
  check int64 "valid ISO8601 maps to epoch milliseconds" 1577836800000L
    (Server_presence.last_seen_ms ~context:"test presence" valid);
  let invalid = { valid with Masc_domain.last_seen = "not-a-timestamp" } in
  check int64 "invalid timestamp maps to 0" 0L
    (Server_presence.last_seen_ms ~context:"test presence" invalid)
;;

let test_post_annotations_rejects_anonymous_create () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations"
        ~body:(annotation_body ~file_path:"lib/a.ml")
        ()
    in
    let response = dispatch router request in
    check_status "anonymous annotation create is rejected" 401 response)
;;

let test_post_annotations_rejects_client_keeper_id () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body =
      {|{"file_path":"lib/a.ml","line_start":1,"line_end":2,"content":"note","keeper_id":"bob"}|}
    in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations"
        ~body
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "client keeper_id cannot override token identity" 403 response)
;;

let test_post_annotations_rejects_unknown_route_fields () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body =
      Yojson.Safe.to_string
        (`Assoc
            [ "file_path", `String "lib/a.ml"
            ; "line_start", `Int 1
            ; "line_end", `Int 2
            ; "content", `String "note"
            ; ("pr_" ^ "id"), `String "external-product-value"
            ])
    in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations"
        ~body
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST with unknown route field returns 400" 400 response;
    check string "unknown route field has typed error code" "invalid_annotation_request"
      (error_code_of_response response))
;;

let test_post_cursors_accepts_client_keeper_id_without_auth () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let body = {|{"file_path":"lib/a.ml","line":1,"keeper_id":"bob"}|} in
    let request = http_request ~meth:`POST ~path:"/api/v1/ide/cursors" ~body () in
    let response = dispatch router request in
    check_status "POST cursor with keeper_id returns 201" 201 response)
;;

let test_post_cursors_rejects_invalid_focus_mode () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body = {|{"file_path":"lib/a.ml","line":1,"focus_mode":"hovering"}|} in
    let request = http_request ~meth:`POST ~path:"/api/v1/ide/cursors" ~body ~token:(Some token) () in
    let response = dispatch router request in
    check_status "POST cursor with invalid focus_mode returns 400" 400 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    check
      string
      "invalid focus_mode error"
      "focus_mode must be one of reading, editing, reviewing, planning"
      (json_string_member "invalid focus_mode response" "error" json);
    check
      string
      "invalid focus_mode code"
      "invalid_focus_mode"
      (json_string_member "invalid focus_mode response" "code" json))
;;

let test_post_cursors_rejects_negative_column () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body = {|{"file_path":"lib/a.ml","line":7,"column":-1}|} in
    let request =
      http_request ~meth:`POST ~path:"/api/v1/ide/cursors" ~body ~token:(Some token) ()
    in
    let response = dispatch router request in
    check_status "POST cursor with negative column returns 400" 400 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    check
      string
      "negative column error"
      "column must be >= 0"
      (json_string_member "negative column response" "error" json))
;;

let test_post_cursors_persists_valid_focus_mode () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body = {|{"file_path":"lib/a.ml","line":7,"focus_mode":"reviewing"}|} in
    let post_request =
      http_request
        ~meth:`POST
        ~path:(scoped_ide_path "/api/v1/ide/cursors")
        ~body
        ~token:(Some token)
        ()
    in
    let post_response = dispatch router post_request in
    check_status "POST cursor with valid focus_mode returns 201" 201 post_response;
    let get_request =
      http_request ~meth:`GET ~path:(scoped_ide_path "/api/v1/ide/cursors") ()
    in
    let get_response = dispatch router get_request in
    check_status "GET cursors after POST succeeds" 200 get_response;
    let json = get_response |> response_body |> Yojson.Safe.from_string in
    let data = Json.member "data" json in
    match json_list_member "cursor snapshot" "cursors" data with
    | cursor :: _ ->
      check
        string
        "persisted focus_mode"
        "reviewing"
        (json_string_member "cursor" "focus_mode" cursor)
    | [] -> fail "expected persisted cursor")
;;

let test_post_cursors_broadcasts_ws_invalidation () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let subscriber_id = "test-ide-cursor-ws-invalidation" in
    let received = ref [] in
    Sse.subscribe_external ~id:subscriber_id
      ~callback:(fun (ev : Sse.external_event) ->
        received := ev.Sse.ext_frame :: !received)
      ();
    Fun.protect
      ~finally:(fun () -> Sse.unsubscribe_external subscriber_id)
      (fun () ->
        let body = {|{"file_path":"lib/a.ml","line":7,"focus_mode":"reviewing"}|} in
        let request =
          http_request
            ~meth:`POST
            ~path:(scoped_ide_path "/api/v1/ide/cursors")
            ~body
            ~token:(Some token)
            ()
        in
        let response = dispatch router request in
        check_status "POST cursor returns 201" 201 response;
        match !received with
        | frame :: _ ->
          (match Sse.data_payload_of_frame frame with
           | Error Sse.Missing_data_payload -> fail "cursor invalidation frame has no data"
           | Ok payload ->
             let json = Yojson.Safe.from_string payload in
             check string "cursor invalidation type" "ide_cursor_changed"
               (json_string_member "cursor invalidation" "type" json);
             check string "cursor invalidation keeper" "alice"
               (json_string_member "cursor invalidation" "keeper_id" json))
        | [] -> fail "POST cursor did not broadcast a websocket invalidation"))
;;

let test_hook_cursors_broadcast_ws_invalidation () =
  with_ide_server (fun ~base_path ~state:_ ~router:_ ->
    let subscriber_id = "test-hook-cursor-ws-invalidation" in
    let received = ref [] in
    Sse.subscribe_external ~id:subscriber_id
      ~callback:(fun (ev : Sse.external_event) ->
        received := ev.Sse.ext_frame :: !received)
      ();
    Fun.protect
      ~finally:(fun () -> Sse.unsubscribe_external subscriber_id)
      (fun () ->
        Ide_bridge.ingest_tool_event_from_hook
          ~base_path
          ~partition:Ide_paths.Legacy_default
          ~tool_name:"keeper_ide_annotate"
          ~keeper_id:"alice"
          ~turn_id:"turn-7"
          ~outcome:"ok"
          ~typed_outcome_str:"progress"
          ~duration_ms:10.0
          ~output_text:"annotated"
          ~input:
            (`Assoc
               [ "file_path", `String "lib/a.ml"
               ; "line_start", `Int 7
               ; "focus_mode", `String "editing"
               ]);
        match !received with
        | frame :: _ ->
          (match Sse.data_payload_of_frame frame with
           | Error Sse.Missing_data_payload -> fail "hook cursor invalidation frame has no data"
           | Ok payload ->
             let json = Yojson.Safe.from_string payload in
             check string "hook cursor invalidation type" "ide_cursor_changed"
               (json_string_member "hook cursor invalidation" "type" json);
             check string "hook cursor invalidation keeper" "alice"
               (json_string_member "hook cursor invalidation" "keeper_id" json))
        | [] -> fail "tool-hook cursor did not broadcast a websocket invalidation"))
;;

let test_post_cursors_honors_canonical_url_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let scoped_path =
      "/api/v1/ide/cursors?canonical_url=https%3A%2F%2Fgithub.com%2Fjeong-sik%2Fmasc.git"
    in
    let body = {|{"file_path":"lib/a.ml","line":9,"focus_mode":"editing"}|} in
    let post_request =
      http_request ~meth:`POST ~path:scoped_path ~body ~token:(Some token) ()
    in
    let post_response = dispatch router post_request in
    check_status "POST cursor with canonical_url scope returns 201" 201 post_response;
    let unscoped_request = http_request ~meth:`GET ~path:"/api/v1/ide/cursors" () in
    let unscoped_response = dispatch router unscoped_request in
    check_status "GET unscoped cursors uses the default scope" 200 unscoped_response;
    let scoped_request = http_request ~meth:`GET ~path:scoped_path () in
    let scoped_response = dispatch router scoped_request in
    check_status "GET scoped cursors succeeds" 200 scoped_response;
    let scoped_json = scoped_response |> response_body |> Yojson.Safe.from_string in
    let scoped_data = Json.member "data" scoped_json in
    match json_list_member "scoped cursor snapshot" "cursors" scoped_data with
    | cursor :: _ ->
      check string "scoped cursor file" "lib/a.ml" (json_string_member "cursor" "file_path" cursor)
    | [] -> fail "expected scoped cursor")
;;

let test_post_cursors_resolves_partition_from_file_path () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let masc_path, _agent_core_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    (* POST cursor with a file_path that belongs to the scoped repo: the
       server must resolve the write partition from the posted file_path
       (task-1733) and scope it to the repo the file actually belongs to. *)
    let file_path = Filename.concat masc_path "lib/a.ml" in
    let body =
      Yojson.Safe.to_string
        (`Assoc [ "file_path", `String file_path; "line", `Int 9 ])
    in
    let scoped_path =
      "/api/v1/ide/cursors?canonical_url=https%3A%2F%2Fgithub.com%2Fjeong-sik%2Fmasc.git"
    in
    let post_request =
      http_request ~meth:`POST ~path:scoped_path ~body ~token:(Some token) ()
    in
    let post_response = dispatch router post_request in
    check_status "POST cursor with matching file_path returns 201" 201 post_response;
    let get_request = http_request ~meth:`GET ~path:scoped_path () in
    let get_response = dispatch router get_request in
    check_status "GET scoped cursors after file_path-resolved POST succeeds" 200 get_response;
    let json = get_response |> response_body |> Yojson.Safe.from_string in
    let data = Json.member "data" json in
    match json_list_member "scoped cursor snapshot" "cursors" data with
    | cursor :: _ ->
      check string "scoped cursor file" "lib/a.ml"
        (json_string_member "cursor" "file_path" cursor)
    | [] -> fail "expected file_path-resolved cursor")
;;

let test_post_cursors_uses_file_path_partition_over_stale_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _masc_path, agent_core_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    (* The file path is current evidence; a stale picker must not prevent a
       cursor event from reaching the repository it actually belongs to. *)
    let file_path = Filename.concat agent_core_path "lib/a.ml" in
    let body =
      Yojson.Safe.to_string
        (`Assoc [ "file_path", `String file_path; "line", `Int 9 ])
    in
    let scoped_path =
      "/api/v1/ide/cursors?canonical_url=https%3A%2F%2Fgithub.com%2Fjeong-sik%2Fmasc.git"
    in
    let post_request =
      http_request ~meth:`POST ~path:scoped_path ~body ~token:(Some token) ()
    in
    let post_response = dispatch router post_request in
    check_status "POST cursor with stale scope returns 201" 201 post_response;
    let actual_repo_request =
      http_request ~meth:`GET ~path:"/api/v1/ide/cursors?repo_id=agent_core" ()
    in
    let actual_repo_response = dispatch router actual_repo_request in
    check_status "GET actual cursor partition succeeds" 200 actual_repo_response;
    let json = actual_repo_response |> response_body |> Yojson.Safe.from_string in
    let data = Json.member "data" json in
    match json_list_member "actual cursor snapshot" "cursors" data with
    | cursor :: _ ->
      check string "cursor follows file path" "lib/a.ml"
        (json_string_member "cursor" "file_path" cursor)
    | [] -> fail "expected cursor in actual repository partition")
;;

let test_post_annotations_accepts_matching_repo_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let masc_path, _agent_core_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    let file_path = Filename.concat masc_path "lib/a.ml" in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations?repo_id=masc"
        ~body:(annotation_body ~file_path)
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation with matching repo_id returns 201" 201 response;
    check
      int
      "matching annotation is visible in requested partition"
      1
      (annotation_count router "/api/v1/ide/annotations?repo_id=masc");
    check
      int
      "matching annotation is not written to other partition"
      0
      (annotation_count router "/api/v1/ide/annotations?repo_id=agent_core"))
;;

let test_post_annotations_uses_file_path_partition_over_stale_repo_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _masc_path, agent_core_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    let file_path = Filename.concat agent_core_path "lib/a.ml" in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations?repo_id=masc"
        ~body:(annotation_body ~file_path)
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation with stale repo_id returns 201" 201 response;
    check
      int
      "stale repo partition remains empty"
      0
      (annotation_count router "/api/v1/ide/annotations?repo_id=masc");
    check
      int
      "annotation follows file path to actual partition"
      1
      (annotation_count router "/api/v1/ide/annotations?repo_id=agent_core"))
;;

let test_post_annotations_uses_file_path_partition_over_stale_canonical_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _masc_path, agent_core_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    let file_path = Filename.concat agent_core_path "lib/a.ml" in
    let scoped_path =
      "/api/v1/ide/annotations?canonical_url="
      ^ Uri.pct_encode "https://github.com/jeong-sik/masc.git"
    in
    let request =
      http_request
        ~meth:`POST
        ~path:scoped_path
        ~body:(annotation_body ~file_path)
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation with stale canonical_url returns 201" 201 response;
    check
      int
      "stale canonical partition remains empty"
      0
      (annotation_count router "/api/v1/ide/annotations?repo_id=masc");
    check
      int
      "annotation follows file path despite stale canonical scope"
      1
      (annotation_count router "/api/v1/ide/annotations?repo_id=agent_core"))
;;

let test_post_annotations_binds_token_identity () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations"
        ~body:(annotation_body ~file_path:"lib/a.ml")
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "authenticated annotation create returns 201" 201 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    let annotation = Json.member "data" json in
    check string "annotation uses token-bound identity" "alice"
      (json_string_member "authenticated annotation" "keeper_id" annotation))
;;

let test_delete_annotation_rejects_cross_owner () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let annotation =
      match
        Ide_annotations.create
          ~base_dir:base_path
          ~keeper_id:"alice"
          ~file_path:"lib/a.ml"
          ~line_start:1
          ~line_end:1
          ~kind:Ide_annotation_types.Comment
          ~content:"delete me"
          ()
      with
      | Ok annotation -> annotation
      | Error msg -> failf "seed annotation for owner-delete test failed: %s" msg
    in
    let bob_token = create_worker_token base_path "bob" in
    let bob_request =
      http_request
        ~meth:`DELETE
        ~path:("/api/v1/ide/annotations/" ^ annotation.id)
        ~token:(Some bob_token)
        ()
    in
    let bob_response = dispatch router bob_request in
    check_status "cross-owner annotation delete is rejected" 403 bob_response;
    check int "cross-owner delete leaves annotation stored" 1
      (annotation_count router "/api/v1/ide/annotations");
    let alice_token = create_worker_token base_path "alice" in
    let alice_request =
      http_request
        ~meth:`DELETE
        ~path:("/api/v1/ide/annotations/" ^ annotation.id)
        ~token:(Some alice_token)
        ()
    in
    let alice_response = dispatch router alice_request in
    check_status "owner annotation delete returns 204" 204 alice_response;
    check int "owner delete removes annotation" 0
      (annotation_count router "/api/v1/ide/annotations"))
;;

let test_read_annotations_uses_default_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    (match
       Ide_annotations.create
         ~base_dir:base_path
         ~partition:Ide_paths.Legacy_default
         ~keeper_id:"alice"
         ~file_path:"lib/default.ml"
         ~line_start:1
         ~line_end:1
         ~kind:Ide_annotation_types.Comment
         ~content:"default scope annotation"
         ()
     with
     | Ok _ -> ()
     | Error msg -> failf "create default annotation failed: %s" msg);
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/annotations" () in
    let response = dispatch router request in
    check_status "GET annotations without scope uses default scope" 200 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    match json_list_member "default annotations" "data" json with
    | annotation :: _ ->
      check string "default annotation content" "default scope annotation"
        (json_string_member "default annotation" "content" annotation)
    | [] -> fail "expected default-scope annotation")
;;

let test_read_cursors_falls_back_from_unmatched_repo_scope () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/cursors?repo_id=missing-repo" ()
    in
    let response = dispatch router request in
    check_status "GET cursors with unmatched repo_id falls back" 200 response)
;;

let test_get_events_falls_back_from_invalid_canonical_scope () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/events?canonical_url=not-a-url" ()
    in
    let response = dispatch router request in
    check_status "GET events with invalid canonical_url falls back" 200 response)
;;

let test_post_annotations_uses_default_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body = annotation_body ~file_path:"lib/a.ml" in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations"
        ~body
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation without scope uses default scope" 201 response;
    check int "default scope stores annotation" 1
      (annotation_count router "/api/v1/ide/annotations"))
;;

let test_memory_response_declares_annotation_source_contract () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    (match
       Ide_annotations.create
         ~base_dir:base_path
         ~partition:(masc_partition ())
         ~keeper_id:"alice"
         ~file_path:"lib/a.ml"
         ~line_start:1
         ~line_end:1
         ~kind:Ide_annotation_types.Comment
         ~content:"remember annotation source"
         ()
     with
     | Ok _ -> ()
     | Error msg -> failf "create annotation failed: %s" msg);
    let request =
      http_request
        ~meth:`GET
        ~path:(scoped_ide_path "/api/v1/ide/memory?keeper_id=alice")
        ()
    in
    let response = dispatch router request in
    check int "GET memory succeeds" 200 (status_of_response response);
    let json = response |> response_body |> Yojson.Safe.from_string in
    let contract = Json.member "contract" json in
    check
      string
      "memory contract source"
      "ide_annotation"
      (json_string_member "contract" "source_kind" contract);
    check
      string
      "memory contract retrieval"
      "annotation_index_only"
      (json_string_member "contract" "retrieval_status" contract);
    check
      string
      "semantic status"
      "not_configured"
      (json_string_member "contract" "semantic_memory_status" contract);
    let entry =
      match json_list_member "memory response" "entries" json with
      | entry :: _ -> entry
      | [] -> fail "expected memory response entry"
    in
    check
      string
      "entry source"
      "ide_annotation"
      (json_string_member "entry" "source_kind" entry);
    check
      string
      "entry retrieval"
      "annotation_index_only"
      (json_string_member "entry" "retrieval_status" entry))
;;

let test_memory_response_honors_canonical_url_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    (match
       Ide_annotations.create
         ~base_dir:base_path
         ~partition:(masc_partition ())
         ~keeper_id:"alice"
         ~file_path:"lib/scoped.ml"
         ~line_start:4
         ~line_end:4
         ~kind:Ide_annotation_types.Comment
         ~content:"scoped memory"
         ()
     with
     | Ok _ -> ()
     | Error msg -> failf "create scoped annotation failed: %s" msg);
    let unscoped_request =
      http_request ~meth:`GET ~path:"/api/v1/ide/memory?keeper_id=alice" ()
    in
    let unscoped_response = dispatch router unscoped_request in
    check_status "GET unscoped memory uses the default scope" 200 unscoped_response;
    let unscoped_json = unscoped_response |> response_body |> Yojson.Safe.from_string in
    check int "default memory does not leak canonical scope" 0
      (List.length (json_list_member "default memory" "entries" unscoped_json));
    let scoped_path = scoped_ide_path "/api/v1/ide/memory?keeper_id=alice" in
    let scoped_request = http_request ~meth:`GET ~path:scoped_path () in
    let scoped_response = dispatch router scoped_request in
    check int "GET scoped memory succeeds" 200 (status_of_response scoped_response);
    let scoped_json = scoped_response |> response_body |> Yojson.Safe.from_string in
    match json_list_member "scoped memory" "entries" scoped_json with
    | entry :: _ ->
      check
        string
        "scoped memory file"
        "lib/scoped.ml"
        (json_string_member "scoped memory entry" "file_path" entry)
    | [] -> fail "expected scoped memory entry")
;;

(* ── keeper-lane scope ───────────────────────────────────────────────
   Turn/coordination events carry no file, so keepers write them to the
   repo-unattributed lane bucket ([Ide_paths.Legacy_default]). Reads use it
   as a useful fallback. Writes prefer their actual file partition and use the
   same default lane when no repository selection is available. *)

let seed_lane_turn_event ~base_path ~keeper_id ~turn_id ~timestamp_ms =
  Ide_bridge.ingest_turn_event
    ~base_path
    ~partition:Ide_paths.Legacy_default
    ~turn_id
    ~keeper_id
    ~phase:"completed"
    ~model_used:None
    ~tools_used:[]
    ~stop_reason:None
    ~duration_ms:(Some 10)
    ~timestamp_ms
;;

let test_events_keeper_lane_returns_only_lane_events () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    seed_lane_turn_event ~base_path ~keeper_id:"alice" ~turn_id:"turn-alice-1"
      ~timestamp_ms:1700000000000L;
    seed_lane_turn_event ~base_path ~keeper_id:"bob" ~turn_id:"turn-bob-1"
      ~timestamp_ms:1700000001000L;
    let request =
      http_request
        ~meth:`GET
        ~path:"/api/v1/ide/events?keeper_lane=alice"
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "GET keeper-lane events succeeds" 200 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    let data = Json.member "data" json in
    match json_list_member "lane events" "events" data with
    | [ event ] ->
      check string "lane keeper only" "alice"
        (json_string_member "lane event" "keeper_id" event)
    | events -> failf "expected exactly alice's event, got %d" (List.length events))
;;

let test_events_keeper_lane_falls_back_when_repo_scope_is_unusable () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request
        ~meth:`GET
        ~path:"/api/v1/ide/events?keeper_lane=alice&repo_id=masc"
        ()
    in
    let response = dispatch router request in
    check_status "keeper_lane + unusable repo_id falls back" 200 response)
;;

let test_events_keeper_lane_allows_explicit_keeper_filter_override () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    seed_lane_turn_event ~base_path ~keeper_id:"alice" ~turn_id:"turn-alice-1"
      ~timestamp_ms:1700000000000L;
    seed_lane_turn_event ~base_path ~keeper_id:"bob" ~turn_id:"turn-bob-1"
      ~timestamp_ms:1700000001000L;
    let request =
      http_request
        ~meth:`GET
        ~path:"/api/v1/ide/events?keeper_lane=alice&keeper_id=bob"
        ()
    in
    let response = dispatch router request in
    check_status "explicit keeper filter overrides keeper_lane" 200 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    let data = Json.member "data" json in
    match json_list_member "overridden lane events" "events" data with
    | [ event ] ->
      check string "explicit keeper filter wins" "bob"
        (json_string_member "overridden lane event" "keeper_id" event)
    | events -> failf "expected exactly bob's event, got %d" (List.length events))
;;

let test_events_keeper_lane_does_not_require_matching_token () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "bob" in
    seed_lane_turn_event ~base_path ~keeper_id:"alice" ~turn_id:"turn-alice-1"
      ~timestamp_ms:1700000000000L;
    let request =
      http_request
        ~meth:`GET
        ~path:"/api/v1/ide/events?keeper_lane=alice"
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "other keeper token can read lane events" 200 response)
;;

let test_cursors_keeper_lane_filters_to_lane_keeper () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    (let seed keeper_id line =
       match
         Ide_bridge.ingest_cursor_event
           ~base_path
           ~partition:Ide_paths.Legacy_default
           ~keeper_id
           ~file_path:"lib/a.ml"
           ~line
           ~source:"editor"
           ()
       with
       | Ok () -> ()
       | Error msg -> failf "seed cursor for %s failed: %s" keeper_id msg
     in
     seed "alice" 1;
     seed "bob" 2);
    let request =
      http_request
        ~meth:`GET
        ~path:"/api/v1/ide/cursors?keeper_lane=alice"
        ()
    in
    let response = dispatch router request in
    check_status "GET keeper-lane cursors succeeds" 200 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    let data = Json.member "data" json in
    match json_list_member "lane cursors" "cursors" data with
    | [ cursor ] ->
      check string "lane cursor keeper" "alice"
        (json_string_member "lane cursor" "keeper_id" cursor)
    | cursors -> failf "expected exactly alice's cursor, got %d" (List.length cursors))
;;

let test_post_cursors_uses_default_lane_for_keeper_lane_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body = {|{"file_path":"lib/a.ml","line":3}|} in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/cursors?keeper_lane=alice"
        ~body
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST cursor with keeper_lane uses default lane" 201 response)
;;

let test_get_events_rejects_invalid_limit () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/events?limit=not-an-int" () in
    let response = dispatch router request in
    check_status "GET events invalid limit returns 400" 400 response;
    check string "typed limit error" "limit must be an integer" (error_message_of_response response))
;;

let test_get_cursors_rejects_negative_offset () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/cursors?offset=-1" () in
    let response = dispatch router request in
    check_status "GET cursors invalid offset returns 400" 400 response;
    check
      string
      "typed offset error"
      "offset must be greater than or equal to 0"
      (error_message_of_response response))
;;

let test_get_memory_rejects_non_positive_limit () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/memory?limit=0" () in
    let response = dispatch router request in
    check_status "GET memory invalid limit returns 400" 400 response;
    check
      string
      "typed memory limit error"
      "limit must be greater than 0"
      (error_message_of_response response))
;;

let () =
  run
    "server_ide_http"
    [ ( "route_registration"
      , [ test_case "POST /api/v1/ide/annotations registered" `Quick
            test_post_annotations_route_is_registered
        ; test_case "DELETE /api/v1/ide/annotations/ registered" `Quick
            test_delete_annotation_route_is_registered
        ; test_case "POST /api/v1/ide/cursors registered" `Quick
            test_post_cursors_route_is_registered
        ; test_case "read routes stay public" `Quick test_read_routes_stay_public
        ] )
    ; ( "presence_contract"
      , [ test_case
            "presence projects canonical keeper identity and status"
            `Quick
            test_presence_projects_only_canonical_keeper_identity
        ; test_case
            "last_seen_ms shared projection maps valid ISO and invalid to 0"
            `Quick
            test_presence_last_seen_ms_shared_projection
        ] )
    ; ( "scope_contract"
      , [ test_case
            "GET annotations uses default scope"
            `Quick
            test_read_annotations_uses_default_scope
        ; test_case
            "GET cursors falls back from unmatched repo scope"
            `Quick
            test_read_cursors_falls_back_from_unmatched_repo_scope
        ; test_case
            "GET events falls back from invalid canonical_url scope"
            `Quick
            test_get_events_falls_back_from_invalid_canonical_scope
        ; test_case
            "POST annotation uses default scope"
            `Quick
            test_post_annotations_uses_default_scope
        ; test_case
            "GET memory declares annotation source contract"
            `Quick
            test_memory_response_declares_annotation_source_contract
        ; test_case
            "GET memory honors canonical_url scope"
            `Quick
            test_memory_response_honors_canonical_url_scope
        ] )
    ; ( "keeper_lane_scope"
      , [ test_case "GET events keeper_lane returns only lane events" `Quick
            test_events_keeper_lane_returns_only_lane_events
        ; test_case "keeper_lane falls back from unusable repo scope" `Quick
            test_events_keeper_lane_falls_back_when_repo_scope_is_unusable
        ; test_case "keeper_lane permits explicit keeper override" `Quick
            test_events_keeper_lane_allows_explicit_keeper_filter_override
        ; test_case "keeper_lane does not require matching token" `Quick
            test_events_keeper_lane_does_not_require_matching_token
        ; test_case "GET cursors keeper_lane filters to lane keeper" `Quick
            test_cursors_keeper_lane_filters_to_lane_keeper
        ; test_case "POST cursor uses default lane for keeper_lane scope" `Quick
            test_post_cursors_uses_default_lane_for_keeper_lane_scope
        ] )
    ; ( "query_parsing"
      , [ test_case "GET events rejects invalid limit" `Quick
            test_get_events_rejects_invalid_limit
        ; test_case "GET cursors rejects negative offset" `Quick
            test_get_cursors_rejects_negative_offset
        ; test_case "GET memory rejects non-positive limit" `Quick
            test_get_memory_rejects_non_positive_limit
        ] )
    ; ( "public_mutation_flow"
      , [ test_case "POST annotation rejects anonymous create" `Quick
            test_post_annotations_rejects_anonymous_create
        ; test_case "POST annotation rejects client keeper_id override" `Quick
            test_post_annotations_rejects_client_keeper_id
        ; test_case "POST annotation rejects unknown route fields" `Quick
            test_post_annotations_rejects_unknown_route_fields
        ; test_case "POST cursor accepts client keeper_id without auth" `Quick
            test_post_cursors_accepts_client_keeper_id_without_auth
        ; test_case "POST cursor rejects invalid focus_mode" `Quick
            test_post_cursors_rejects_invalid_focus_mode
        ; test_case "POST cursor rejects negative column" `Quick
            test_post_cursors_rejects_negative_column
        ; test_case "POST cursor persists valid focus_mode" `Quick
            test_post_cursors_persists_valid_focus_mode
        ; test_case "POST cursor broadcasts WS invalidation" `Quick
            test_post_cursors_broadcasts_ws_invalidation
        ; test_case "tool-hook cursor broadcasts WS invalidation" `Quick
            test_hook_cursors_broadcast_ws_invalidation
        ; test_case "POST cursor honors canonical_url scope" `Quick
            test_post_cursors_honors_canonical_url_scope
        ; test_case "POST cursor follows file path over stale scope" `Quick
            test_post_cursors_uses_file_path_partition_over_stale_scope
        ; test_case "POST annotation accepts matching repo scope" `Quick
            test_post_annotations_accepts_matching_repo_scope
        ; test_case "POST annotation follows file path over stale repo scope" `Quick
            test_post_annotations_uses_file_path_partition_over_stale_repo_scope
        ; test_case "POST annotation follows file path over stale canonical scope" `Quick
            test_post_annotations_uses_file_path_partition_over_stale_canonical_scope
        ; test_case "POST annotation binds token identity" `Quick
            test_post_annotations_binds_token_identity
        ; test_case "DELETE annotation rejects cross-owner" `Quick
            test_delete_annotation_rejects_cross_owner
        ] )
    ]
;;
