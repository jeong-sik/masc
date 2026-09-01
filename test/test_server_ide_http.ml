(** Black-box HTTP/router tests for [Server_ide_http].

    These tests exercise the public route table and actual response
    statuses rather than relying on [Server_ide_http.For_testing]
    helpers. They guard the security contract from task-1736 B3:
    mutation routes require a bearer token, reject a client-supplied
    [keeper_id], and return the expected status codes. *)

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

let test_read_routes_stay_public () =
  let router = Server_ide_http.add_routes (Http.Router.create ()) in
  check bool "GET /api/v1/ide/annotations" true
    (has_route `GET "/api/v1/ide/annotations" router);
  check bool "GET /api/v1/ide/file-activity" true
    (has_route `GET "/api/v1/ide/file-activity" router)
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
let masc_scope_query = "codebase=github.com_jeong-sik_masc"

let scoped_ide_path path =
  let separator = if String.contains path '?' then "&" else "?" in
  path ^ separator ^ masc_scope_query
;;

let masc_codebase () =
  match Ide_paths.canonical_url_of_remote masc_remote with
  | Some slug -> slug
  | None -> fail "test remote must produce a canonical IDE codebase slug"
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

let test_post_annotations_rejects_client_keeper_id () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body =
      {|{"file_path":"lib/a.ml","line_start":1,"line_end":2,"content":"note","keeper_id":"bob"}|}
    in
    let request = http_request ~meth:`POST ~path:"/api/v1/ide/annotations" ~body ~token:(Some token) () in
    let response = dispatch router request in
    check_status "POST with keeper_id returns 403" 403 response)
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

let test_post_annotations_accepts_matching_repo_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _masc_path, _agent_core_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    (* RFC-0378 §5.3: the posted path is repo-root-relative — the same
       vocabulary the co-view hands out and the repo-scoped read queries. *)
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc"
        ~body:(annotation_body ~file_path:"lib/a.ml")
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation with a codebase scope returns 201" 201 response;
    check
      int
      "matching annotation is visible in the requested codebase"
      1
      (annotation_count router "/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc");
    check
      int
      "matching annotation is not written to another codebase"
      0
      (annotation_count router "/api/v1/ide/annotations?codebase=example.com_agent-core"))
;;

let test_post_annotations_rejects_absolute_file_path () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _masc_path, agent_core_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    (* RFC-0378 §5.3: an absolute path is not the co-view vocabulary —
       typed reject at the mint, and nothing lands in any store. *)
    let file_path = Filename.concat agent_core_path "lib/a.ml" in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc"
        ~body:(annotation_body ~file_path)
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation with an absolute file_path returns 400" 400 response;
    check
      string
      "mint reject code"
      "invalid_file_path"
      (error_code_of_response response);
    check
      int
      "rejected annotation is not written to the scoped codebase"
      0
      (annotation_count router "/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc");
    check
      int
      "rejected annotation is not written to any other codebase"
      0
      (annotation_count router "/api/v1/ide/annotations?codebase=example.com_agent-core"))
;;

let test_post_annotations_rejects_escaping_file_path () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _repos = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    let scoped_path =
      "/api/v1/ide/annotations?codebase=github.com_jeong-sik_masc"
    in
    let request =
      http_request
        ~meth:`POST
        ~path:scoped_path
        ~body:(annotation_body ~file_path:"../escape.ml")
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation with an escaping file_path returns 400" 400 response;
    check
      string
      "mint reject code"
      "invalid_file_path"
      (error_code_of_response response))
;;

let test_post_annotations_requires_auth () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let body = {|{"file_path":"lib/a.ml","line_start":1,"line_end":2,"content":"note"}|} in
    let request = http_request ~meth:`POST ~path:"/api/v1/ide/annotations" ~body () in
    let response = dispatch router request in
    check int "POST without token returns 401/403" 401 (status_of_response response))
;;

let test_delete_annotation_requires_auth () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`DELETE ~path:"/api/v1/ide/annotations/ann-1" () in
    let response = dispatch router request in
    check int "DELETE without token returns 401/403" 401 (status_of_response response))
;;

let test_read_annotations_rejects_missing_scope () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/annotations" () in
    let response = dispatch router request in
    check_status "GET annotations without scope returns 400" 400 response;
    check
      string
      "missing scope error"
      "IDE scope is required; pass codebase=<slug>"
      (error_message_of_response response);
    check
      string
      "missing scope code"
      "missing_ide_scope"
      (error_code_of_response response))
;;

let test_read_events_accepts_unknown_codebase_as_empty () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    (* RFC-0378 §5.4: the scope universe is store-measured, not the
       catalog — an unknown slug is a legitimate empty store, not a
       registry miss. *)
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/events?codebase=github.com_x_missing" ()
    in
    let response = dispatch router request in
    check_status "GET events with an unknown codebase returns 200" 200 response)
;;

let test_get_events_rejects_invalid_canonical_scope () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/events?codebase=Not%%20A%%20Slug" ()
    in
    let response = dispatch router request in
    check_status "GET events with an invalid codebase returns 400" 400 response;
    check
      string
      "invalid codebase code"
      "invalid_codebase"
      (error_code_of_response response))
;;

let test_post_annotations_rejects_missing_scope () =
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
    check_status "POST annotation without scope returns 400" 400 response;
    check
      string
      "POST annotation missing scope code"
      "missing_ide_scope"
      (error_code_of_response response))
;;

let test_memory_response_declares_annotation_source_contract () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    (match
       Ide_annotations.create
         ~base_dir:base_path
         ~codebase:(masc_codebase ())
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
         ~codebase:(masc_codebase ())
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
    check
      int
      "GET unscoped memory rejects missing scope"
      400
      (status_of_response unscoped_response);
    check
      string
      "GET unscoped memory error code"
      "missing_ide_scope"
      (error_code_of_response unscoped_response);
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

let test_get_events_rejects_invalid_limit () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/events?limit=not-an-int" () in
    let response = dispatch router request in
    check_status "GET events invalid limit returns 400" 400 response;
    check string "typed limit error" "limit must be an integer" (error_message_of_response response))
;;

let test_get_events_rejects_negative_offset () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/events?offset=-1" () in
    let response = dispatch router request in
    check_status "GET events invalid offset returns 400" 400 response;
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

let test_get_file_activity_requires_a_file_path () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/file-activity" () in
    let response = dispatch router request in
    check_status "GET file activity without file path returns 400" 400 response;
    check string "typed missing file path" "file_path is required"
      (error_message_of_response response))
;;

let test_get_file_activity_rejects_invalid_window () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET
        ~path:
          "/api/v1/ide/file-activity?repo_id=masc&file_path=bin/x.ml&window_hours=0"
        ()
    in
    let response = dispatch router request in
    check_status "GET file activity invalid window returns 400" 400 response;
    check string "typed invalid window"
      "window_hours must be a positive number: 0"
      (error_message_of_response response))
;;

let test_get_file_activity_resolves_the_project_checkout_exactly () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let repository =
      repository_fixture ~id:"project-masc" ~url:masc_remote
        ~local_path:base_path
    in
    (match Repo_store.save_all ~base_path [ repository ] with
     | Ok () -> ()
     | Error detail -> fail detail);
    let request =
      http_request ~meth:`GET
        ~path:"/api/v1/ide/file-activity?file_path=bin/masc_tui.ml" ()
    in
    let response = dispatch router request in
    check_status "GET project file activity returns 200" 200 response;
    let envelope = response |> response_body |> Yojson.Safe.from_string in
    let data = Json.member "data" envelope in
    check string "server-derived repository id" "project-masc"
      (json_string_member "file activity" "repo_id" data);
    check string "durable projection schema" "masc.ide.file_activity.v1"
      (json_string_member "file activity" "schema" data))
;;

let () =
  run
    "server_ide_http"
    [ ( "route_registration"
      , [ test_case "POST /api/v1/ide/annotations registered" `Quick
            test_post_annotations_route_is_registered
        ; test_case "DELETE /api/v1/ide/annotations/ registered" `Quick
            test_delete_annotation_route_is_registered
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
            "GET annotations rejects missing scope"
            `Quick
            test_read_annotations_rejects_missing_scope
        ; test_case
            "GET events accepts an unknown codebase as empty"
            `Quick
            test_read_events_accepts_unknown_codebase_as_empty
        ; test_case
            "GET events rejects an invalid codebase scope"
            `Quick
            test_get_events_rejects_invalid_canonical_scope
        ; test_case
            "POST annotation rejects missing scope"
            `Quick
            test_post_annotations_rejects_missing_scope
        ; test_case
            "GET memory declares annotation source contract"
            `Quick
            test_memory_response_declares_annotation_source_contract
        ; test_case
            "GET memory honors the codebase scope"
            `Quick
            test_memory_response_honors_canonical_url_scope
        ] )
    ; ( "query_parsing"
      , [ test_case "GET events rejects invalid limit" `Quick
            test_get_events_rejects_invalid_limit
        ; test_case "GET events rejects negative offset" `Quick
            test_get_events_rejects_negative_offset
        ; test_case "GET memory rejects non-positive limit" `Quick
            test_get_memory_rejects_non_positive_limit
        ; test_case "GET file activity requires file path" `Quick
            test_get_file_activity_requires_a_file_path
        ; test_case "GET file activity rejects invalid window" `Quick
            test_get_file_activity_rejects_invalid_window
        ; test_case "GET file activity resolves project checkout" `Quick
            test_get_file_activity_resolves_the_project_checkout_exactly
        ] )
    ; ( "mutation_auth"
      , [ test_case "POST annotation rejects client keeper_id" `Quick
            test_post_annotations_rejects_client_keeper_id
        ; test_case "POST annotation rejects unknown route fields" `Quick
            test_post_annotations_rejects_unknown_route_fields
        ; test_case "POST annotation accepts matching repo scope" `Quick
            test_post_annotations_accepts_matching_repo_scope
        ; test_case "POST annotation rejects an absolute file_path" `Quick
            test_post_annotations_rejects_absolute_file_path
        ; test_case "POST annotation rejects an escaping file_path" `Quick
            test_post_annotations_rejects_escaping_file_path
        ; test_case "POST annotation requires auth" `Quick
            test_post_annotations_requires_auth
        ; test_case "DELETE annotation requires auth" `Quick
            test_delete_annotation_requires_auth
        ] )
    ]
;;
