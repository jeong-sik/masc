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

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
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

let json_int_member label key json =
  match Json.member key json with
  | `Int value -> value
  | other -> failf "%s: expected int member %s, got %s" label key (Yojson.Safe.to_string other)
;;

let json_list_member label key json =
  match Json.member key json with
  | `List values -> values
  | other -> failf "%s: expected list member %s, got %s" label key (Yojson.Safe.to_string other)
;;

let json_data_member label json =
  match Json.member "data" json with
  | `Assoc _ as data -> data
  | other -> failf "%s: expected data object, got %s" label (Yojson.Safe.to_string other)
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

let orphan_read_count reason =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_ide_orphan_reads
    ~labels:[ "reason", reason ]
    ()
;;

let test_read_annotations_records_legacy_default_orphan_metric () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let before = orphan_read_count "legacy_default" in
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/annotations" () in
    let response = dispatch router request in
    check int "GET annotations succeeds" 200 (status_of_response response);
    let after = orphan_read_count "legacy_default" in
    check (float 0.0001) "legacy_default orphan read increments" (before +. 1.0) after)
;;

let test_read_cursors_records_unmatched_repo_orphan_metric () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let before = orphan_read_count "unmatched" in
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/cursors?repo_id=missing-repo" ()
    in
    let response = dispatch router request in
    check int "GET cursors succeeds" 200 (status_of_response response);
    let after = orphan_read_count "unmatched" in
    check (float 0.0001) "unmatched orphan read increments" (before +. 1.0) after)
;;

let test_read_cursors_records_repo_lookup_error_orphan_metric () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let config_dir =
      Filename.concat (Filename.concat base_path Common.masc_dirname) "config"
    in
    Unix.mkdir config_dir 0o700;
    write_file (Filename.concat config_dir "repositories.toml") "[repository.bad\n";
    let before = orphan_read_count "base_unresolved" in
    let request = http_request ~meth:`GET ~path:"/api/v1/ide/cursors?repo_id=masc" () in
    let response = dispatch router request in
    check int "GET cursors succeeds" 200 (status_of_response response);
    let after = orphan_read_count "base_unresolved" in
    check (float 0.0001) "base_unresolved orphan read increments" (before +. 1.0) after)
;;

let test_status_reports_workspace_state_read_error () =
  with_ide_server (fun ~base_path:_ ~state ~router ->
    let config = Masc.Mcp_server.workspace_config state in
    let state_path = Masc.Workspace.state_path config in
    if Sys.file_exists state_path then Sys.remove state_path;
    let request = http_request ~meth:`GET ~path:"/api/v1/status" () in
    let response = dispatch router request in
    check_status "GET status succeeds with missing state" 200 response;
    let json = response |> response_body |> Yojson.Safe.from_string in
    let data = json_data_member "status response" json in
    check
      string
      "workspace_state_status"
      "default_from_read_error"
      (json_string_member "status data" "workspace_state_status" data);
    check
      int
      "workspace_state_read_error_count"
      1
      (json_int_member "status data" "workspace_state_read_error_count" data);
    match json_list_member "status data" "workspace_state_read_errors" data with
    | _ :: _ -> ()
    | [] -> fail "expected workspace_state_read_errors to explain the read failure")
;;

let test_memory_response_declares_annotation_source_contract () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    (match
       Ide_annotations.create
         ~base_dir:base_path
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
      http_request ~meth:`GET ~path:"/api/v1/ide/memory?keeper_id=alice" ()
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

let test_memory_invalid_limit_uses_observed_default () =
  with_ide_server (fun ~base_path:_ ~state:_ ~router ->
    let request =
      http_request ~meth:`GET ~path:"/api/v1/ide/memory?limit=not-an-int" ()
    in
    let response = dispatch router request in
    check int "GET memory succeeds" 200 (status_of_response response);
    let json = response |> response_body |> Yojson.Safe.from_string in
    check int "invalid limit falls back to default" 50 (Json.member "limit" json |> Json.to_int))
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
    ; ( "read_metrics"
      , [ test_case
            "GET annotations records legacy_default orphan read metric"
            `Quick
            test_read_annotations_records_legacy_default_orphan_metric
        ; test_case
            "GET cursors records unmatched repo orphan read metric"
            `Quick
            test_read_cursors_records_unmatched_repo_orphan_metric
        ; test_case
            "GET cursors records repo lookup-error orphan read metric"
            `Quick
            test_read_cursors_records_repo_lookup_error_orphan_metric
        ; test_case
            "GET status reports workspace state read error"
            `Quick
            test_status_reports_workspace_state_read_error
        ; test_case
            "GET memory declares annotation source contract"
            `Quick
            test_memory_response_declares_annotation_source_contract
        ; test_case
            "GET memory invalid limit uses observed default"
            `Quick
            test_memory_invalid_limit_uses_observed_default
        ] )
    ; ( "mutation_auth"
      , [ test_case "POST annotation rejects client keeper_id" `Quick
            test_post_annotations_rejects_client_keeper_id
        ; test_case "POST cursor rejects client keeper_id" `Quick
            test_post_cursors_rejects_client_keeper_id
        ; test_case "POST annotation requires auth" `Quick
            test_post_annotations_requires_auth
        ; test_case "DELETE annotation requires auth" `Quick
            test_delete_annotation_requires_auth
        ] )
    ]
;;
