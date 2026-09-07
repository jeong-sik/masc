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

let test_read_routes_stay_public () =
  let router = Server_ide_http.add_routes (Http.Router.create ()) in
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

let create_admin_token base_path agent_name =
  match Auth.create_token base_path ~agent_name ~role:Masc_domain.Admin with
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

let masc_remote = "https://github.com/jeong-sik/masc.git"

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

(* The rows carry keeper-written file text, the same content
   [/api/v1/keepers/:name/file-changes] keeps behind CanAdmin. *)
let test_file_activity_requires_auth () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/file-activity?file_path=lib/a.ml" ()
    in
    let response = dispatch router request in
    check int "GET file-activity without token returns 401" 401 (status_of_response response))
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

let test_get_file_activity_requires_a_file_path () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_admin_token base_path "operator" in
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/file-activity" ~token:(Some token) ()
    in
    let response = dispatch router request in
    check_status "GET file activity without file path returns 400" 400 response;
    check string "typed missing file path" "file_path is required"
      (error_message_of_response response))
;;

let test_get_file_activity_rejects_invalid_window () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_admin_token base_path "operator" in
    let request =
      http_request ~meth:`GET
        ~path:
          "/api/v1/ide/file-activity?repo_id=masc&file_path=bin/x.ml&window_hours=0"
        ~token:(Some token) ()
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
    let token = create_admin_token base_path "operator" in
    let request =
      http_request ~meth:`GET
        ~path:"/api/v1/ide/file-activity?file_path=bin/masc_tui.ml"
        ~token:(Some token) ()
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
      , [ test_case "read routes stay public" `Quick test_read_routes_stay_public ] )
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
            "GET events accepts an unknown codebase as empty"
            `Quick
            test_read_events_accepts_unknown_codebase_as_empty
        ; test_case
            "GET events rejects an invalid codebase scope"
            `Quick
            test_get_events_rejects_invalid_canonical_scope
        ] )
    ; ( "query_parsing"
      , [ test_case "GET events rejects invalid limit" `Quick
            test_get_events_rejects_invalid_limit
        ; test_case "GET events rejects negative offset" `Quick
            test_get_events_rejects_negative_offset
        ; test_case "GET file activity requires file path" `Quick
            test_get_file_activity_requires_a_file_path
        ; test_case "GET file activity rejects invalid window" `Quick
            test_get_file_activity_rejects_invalid_window
        ; test_case "GET file activity resolves project checkout" `Quick
            test_get_file_activity_resolves_the_project_checkout_exactly
        ; test_case "GET file activity without a token returns 401" `Quick
            test_file_activity_requires_auth
        ] )
    ]
;;
