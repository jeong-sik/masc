(** Black-box HTTP/router tests for [Server_ide_http].

    These tests exercise the public route table and actual response
    statuses rather than relying on [Server_ide_http.For_testing]
    helpers. They guard the security contract from task-1736 B3:
    mutation routes require a bearer token, reject a client-supplied
    [keeper_id], and return the expected status codes. *)

open Alcotest

module Auth = Masc.Auth
module Http = Masc.Http_server_eio
module Json = Yojson.Safe.Util

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
  check bool "GET /api/v1/ide/annotations" true
    (has_route `GET "/api/v1/ide/annotations" router);
  check bool "GET /api/v1/ide/cursors" true
    (has_route `GET "/api/v1/ide/cursors" router)
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
  let oas_path = Filename.concat base_path "workspace/oas" in
  let repos =
    [ repository_fixture
        ~id:"masc"
        ~url:"https://github.com/jeong-sik/masc.git"
        ~local_path:masc_path
    ; repository_fixture
        ~id:"oas"
        ~url:"https://github.com/jeong-sik/oas.git"
        ~local_path:oas_path
    ]
  in
  match Repo_store.save_all ~base_path repos with
  | Ok () -> masc_path, oas_path
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
  let state = Masc.Mcp_server.create_state ~base_path in
  Server_auth.server_state := Some state;
  state
;;

let with_ide_server f =
  with_temp_workspace (fun base_path ->
    let saved_state = !Server_auth.server_state in
    Fun.protect
      ~finally:(fun () -> Server_auth.server_state := saved_state)
      (fun () ->
         let state = setup_state base_path in
         let router = Server_ide_http.add_routes (Http.Router.create ()) in
         f ~base_path ~state ~router))
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

let test_post_cursors_rejects_client_keeper_id () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body = {|{"file_path":"lib/a.ml","line":1,"keeper_id":"bob"}|} in
    let request = http_request ~meth:`POST ~path:"/api/v1/ide/cursors" ~body ~token:(Some token) () in
    let response = dispatch router request in
    check_status "POST cursor with keeper_id returns 403" 403 response)
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
    check
      int
      "GET unscoped cursors rejects missing scope"
      400
      (status_of_response unscoped_response);
    check
      string
      "GET unscoped cursors error code"
      "missing_ide_scope"
      (error_code_of_response unscoped_response);
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

let test_post_annotations_accepts_matching_repo_scope () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let masc_path, _oas_path = seed_annotation_scope_repos base_path in
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
      (annotation_count router "/api/v1/ide/annotations?repo_id=oas"))
;;

let test_post_annotations_rejects_repo_scope_mismatch () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _masc_path, oas_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    let file_path = Filename.concat oas_path "lib/a.ml" in
    let request =
      http_request
        ~meth:`POST
        ~path:"/api/v1/ide/annotations?repo_id=masc"
        ~body:(annotation_body ~file_path)
        ~token:(Some token)
        ()
    in
    let response = dispatch router request in
    check_status "POST annotation with mismatched repo_id returns 400" 400 response;
    check
      string
      "repo scope mismatch error"
      "file_path does not belong to requested repo_id"
      (error_message_of_response response);
    check
      string
      "repo scope mismatch code"
      "repo_mismatch"
      (error_code_of_response response);
    check
      int
      "mismatched annotation is not written to requested partition"
      0
      (annotation_count router "/api/v1/ide/annotations?repo_id=masc");
    check
      int
      "mismatched annotation is not written to actual partition"
      0
      (annotation_count router "/api/v1/ide/annotations?repo_id=oas"))
;;

let test_post_annotations_rejects_canonical_scope_mismatch () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let _masc_path, oas_path = seed_annotation_scope_repos base_path in
    let token = create_worker_token base_path "alice" in
    let file_path = Filename.concat oas_path "lib/a.ml" in
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
    check_status "POST annotation with mismatched canonical_url returns 400" 400 response;
    check
      string
      "canonical scope mismatch error"
      "file_path does not belong to requested canonical_url"
      (error_message_of_response response);
    check
      string
      "canonical scope mismatch code"
      "canonical_url_mismatch"
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
      "IDE scope is required; pass repo_id, canonical_url, or keeper_lane"
      (error_message_of_response response);
    check
      string
      "missing scope code"
      "missing_ide_scope"
      (error_code_of_response response))
;;

let test_read_cursors_rejects_unmatched_repo_scope () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/cursors?repo_id=missing-repo" ()
    in
    let response = dispatch router request in
    check_status "GET cursors with unmatched repo_id returns 400" 400 response;
    check
      string
      "unmatched repo error code"
      "unmatched_repo_id"
      (error_code_of_response response))
;;

let test_get_events_rejects_invalid_canonical_scope () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/events?canonical_url=not-a-url" ()
    in
    let response = dispatch router request in
    check_status "GET events with invalid canonical_url returns 400" 400 response;
    check
      string
      "invalid canonical_url code"
      "invalid_canonical_url"
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

let test_cursor_stream_accepts_query_token_under_strict_auth () =
  with_env "MASC_HTTP_BASE_URL" (Some "https://masc.example.test") (fun () ->
    with_ide_server (fun ~base_path ~state:_ ~router ->
      let token = create_worker_token base_path "alice" in
      let path =
        scoped_ide_path "/api/v1/ide/cursors/stream"
        ^ "&token="
        ^ Uri.pct_encode token
      in
      let request = http_request ~meth:`GET ~path () in
      let response = dispatch router request in
      check_status "GET cursor stream with query token succeeds" 200 response))
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

(* ── keeper-lane scope ───────────────────────────────────────────────
   Turn/coordination events carry no file, so keepers write them to the
   repo-unattributed lane bucket ([Ide_paths.Legacy_default]). These tests
   pin the read contract: [?keeper_lane=<id>] reads that bucket filtered
   to the lane keeper, conflicts with repo scopes, and never authorizes
   mutations. *)

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
    seed_lane_turn_event ~base_path ~keeper_id:"alice" ~turn_id:"turn-alice-1"
      ~timestamp_ms:1700000000000L;
    seed_lane_turn_event ~base_path ~keeper_id:"bob" ~turn_id:"turn-bob-1"
      ~timestamp_ms:1700000001000L;
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/events?keeper_lane=alice" ()
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

let test_events_keeper_lane_conflicts_with_repo_scope () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request
        ~meth:`GET
        ~path:"/api/v1/ide/events?keeper_lane=alice&repo_id=masc"
        ()
    in
    let response = dispatch router request in
    check_status "keeper_lane + repo_id returns 400" 400 response;
    check string "conflict code" "conflicting_ide_scope" (error_code_of_response response))
;;

let test_events_keeper_lane_rejects_mismatched_keeper_filter () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request
        ~meth:`GET
        ~path:"/api/v1/ide/events?keeper_lane=alice&keeper_id=bob"
        ()
    in
    let response = dispatch router request in
    check_status "mismatched keeper filter returns 400" 400 response;
    check
      string
      "filter conflict code"
      "keeper_lane_filter_conflict"
      (error_code_of_response response))
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
      http_request ~meth:`GET ~path:"/api/v1/ide/cursors?keeper_lane=alice" ()
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

let test_post_cursors_rejects_keeper_lane_scope () =
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
    check_status "POST cursor with keeper_lane returns 400" 400 response;
    check
      string
      "read-only scope code"
      "keeper_lane_read_only"
      (error_code_of_response response))
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
    ; ( "scope_contract"
      , [ test_case
            "GET annotations rejects missing scope"
            `Quick
            test_read_annotations_rejects_missing_scope
        ; test_case
            "GET cursors rejects unmatched repo scope"
            `Quick
            test_read_cursors_rejects_unmatched_repo_scope
        ; test_case
            "GET events rejects invalid canonical_url scope"
            `Quick
            test_get_events_rejects_invalid_canonical_scope
        ; test_case
            "POST annotation rejects missing scope"
            `Quick
            test_post_annotations_rejects_missing_scope
        ; test_case
            "GET cursor stream accepts query token under strict auth"
            `Quick
            test_cursor_stream_accepts_query_token_under_strict_auth
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
        ; test_case "keeper_lane conflicts with repo scope" `Quick
            test_events_keeper_lane_conflicts_with_repo_scope
        ; test_case "keeper_lane rejects mismatched keeper filter" `Quick
            test_events_keeper_lane_rejects_mismatched_keeper_filter
        ; test_case "GET cursors keeper_lane filters to lane keeper" `Quick
            test_cursors_keeper_lane_filters_to_lane_keeper
        ; test_case "POST cursor rejects keeper_lane scope" `Quick
            test_post_cursors_rejects_keeper_lane_scope
        ] )
    ; ( "query_parsing"
      , [ test_case "GET events rejects invalid limit" `Quick
            test_get_events_rejects_invalid_limit
        ; test_case "GET cursors rejects negative offset" `Quick
            test_get_cursors_rejects_negative_offset
        ; test_case "GET memory rejects non-positive limit" `Quick
            test_get_memory_rejects_non_positive_limit
        ] )
    ; ( "mutation_auth"
      , [ test_case "POST annotation rejects client keeper_id" `Quick
            test_post_annotations_rejects_client_keeper_id
        ; test_case "POST cursor rejects client keeper_id" `Quick
            test_post_cursors_rejects_client_keeper_id
        ; test_case "POST cursor rejects invalid focus_mode" `Quick
            test_post_cursors_rejects_invalid_focus_mode
        ; test_case "POST cursor rejects negative column" `Quick
            test_post_cursors_rejects_negative_column
        ; test_case "POST cursor persists valid focus_mode" `Quick
            test_post_cursors_persists_valid_focus_mode
        ; test_case "POST cursor honors canonical_url scope" `Quick
            test_post_cursors_honors_canonical_url_scope
        ; test_case "POST annotation accepts matching repo scope" `Quick
            test_post_annotations_accepts_matching_repo_scope
        ; test_case "POST annotation rejects repo scope mismatch" `Quick
            test_post_annotations_rejects_repo_scope_mismatch
        ; test_case "POST annotation rejects canonical scope mismatch" `Quick
            test_post_annotations_rejects_canonical_scope_mismatch
        ; test_case "POST annotation requires auth" `Quick
            test_post_annotations_requires_auth
        ; test_case "DELETE annotation requires auth" `Quick
            test_delete_annotation_requires_auth
        ] )
    ]
;;
