(** Black-box HTTP/router tests for [Server_ide_http].

    These tests exercise the public route table and actual response
    statuses rather than relying on [Server_ide_http.For_testing]
    helpers. They guard the security contract from task-1736 B3:
    mutation routes require a bearer token, reject a client-supplied
    [keeper_id], and return the expected status codes. *)

open Alcotest

module Auth = Masc.Auth
module Http = Masc.Http_server_eio

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
  let response_buf = Buffer.create 1024 in
  let conn =
    Httpun.Server_connection.create (fun reqd ->
      Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
  in
  let request_bytes =
    let req_str =
      Printf.sprintf
        "%s %s HTTP/1.1\r\n%s\r\n%s"
        (Httpun.Method.to_string request.Httpun.Request.meth)
        request.Httpun.Request.target
        (Httpun.Headers.to_string request.Httpun.Request.headers)
        body
    in
    Bigstringaf.of_string ~off:0 ~len:(String.length req_str) req_str
  in
  ignore
    (Httpun.Server_connection.read conn request_bytes ~off:0 ~len:(Bigstringaf.length request_bytes));
  let rec flush () =
    match Httpun.Server_connection.next_write_operation conn with
    | `Write iovecs ->
      List.iter
        (fun iov ->
           Buffer.add_string
             response_buf
             (Bigstringaf.substring iov.buf ~off:iov.off ~len:iov.len))
        iovecs;
      let written = List.fold_left (fun acc iov -> acc + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result conn (`Ok written);
      flush ()
    | `Yield | `Close _ -> ()
  in
  flush ();
  Buffer.contents response_buf
;;

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse status from response: %S" response
;;

let setup_state base_path =
  save_auth_config base_path;
  let state = Mcp_server.create_state ~base_path in
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
    check int "POST with keeper_id returns 403" 403 (status_of_response response))
;;

let test_post_cursors_rejects_client_keeper_id () =
  with_ide_server (fun ~base_path ~state:_ ~router ->
    let token = create_worker_token base_path "alice" in
    let body = {|{"file_path":"lib/a.ml","line":1,"keeper_id":"bob"}|} in
    let request = http_request ~meth:`POST ~path:"/api/v1/ide/cursors" ~body ~token:(Some token) () in
    let response = dispatch router request in
    check int "POST cursor with keeper_id returns 403" 403 (status_of_response response))
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
