open Alcotest
open Masc

let with_workspace f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect
      ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path in
        f state))
;;

let instance_id state =
  let scope = Mcp_server.workspace_scope state in
  Build_identity.runtime_instance_id ^ "."
  ^ Mcp_server.Workspace_scope_epoch.to_string scope.epoch
;;

let request state headers =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    let req = Httpun.Reqd.request reqd in
    Server_dashboard_http_keeper_api.handle_keeper_get_subroutes state req req reqd) in
  let request_headers =
    headers |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n")
    |> String.concat "" in
  let wire = "GET /api/v1/keepers/alpha/waiting-inventory HTTP/1.1\r\n"
    ^ "Host: localhost\r\n" ^ request_headers ^ "\r\n" in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let length = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok length);
      drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let lines = Buffer.contents output |> String.split_on_char '\n' in
  let status = match lines with
    | first :: _ -> (match String.split_on_char ' ' first with
      | _ :: value :: _ -> int_of_string value
      | _ -> fail "invalid status")
    | [] -> fail "missing response" in
  let header name =
    List.find_map (fun line ->
      match String.index_opt line ':' with
      | Some split when String.equal (String.lowercase_ascii (String.sub line 0 split)) name ->
        Some (String.trim (String.sub line (split + 1) (String.length line - split - 1)))
      | Some _ | None -> None) lines in
  status, header
;;

let test_wrong_instance_is_refused () =
  with_workspace (fun state ->
    let status, _ = request state ["x-masc-sse-instance-id", "another-instance"] in
    check int "different observer generation is refused" 409 status)
;;

let test_matching_instance_and_same_path_replacement () =
  with_workspace (fun state ->
    let previous = instance_id state in
    let status, header = request state ["x-masc-sse-instance-id", previous] in
    check int "matching observer generation can read" 200 status;
    check (option string) "read response attests the same generation"
      (Some previous) (header "x-masc-sse-instance-id");
    (match Mcp_server.set_workspace_config state (Mcp_server.workspace_config state) with
     | Ok () -> ()
     | Error _ -> fail "same-path workspace replacement failed");
    check bool "same path has a new generation" true (instance_id state <> previous);
    let status, _ = request state ["x-masc-sse-instance-id", previous] in
    check int "retired generation cannot read the replacement" 409 status)
;;

let test_duplicate_instance_is_refused () =
  with_workspace (fun state ->
    let instance = instance_id state in
    let status, _ = request state ["x-masc-sse-instance-id", instance; "X-Masc-Sse-Instance-Id", instance] in
    check int "duplicate observer generation is refused" 400 status)
;;

let test_replacement_during_read_refuses_old_result () =
  with_workspace (fun state ->
    let previous = instance_id state in
    let result = Server_observer_scope.read_if_current ~state
      ~expected_instances:[previous]
      ~read:(fun config ->
        (match Mcp_server.set_workspace_config state config with
         | Ok () -> ()
         | Error _ -> fail "same-path workspace replacement failed");
        `String "old observation") in
    check bool "a read crossing replacement cannot publish the old result" true
      (result = Error Server_observer_scope.Scope_changed))
;;

let () =
  run "keeper waiting observer scope"
    [ "HTTP read",
      [ test_case "wrong instance" `Quick test_wrong_instance_is_refused
      ; test_case "same-path workspace replacement" `Quick test_matching_instance_and_same_path_replacement
      ; test_case "duplicate instance" `Quick test_duplicate_instance_is_refused
      ; test_case "replacement during a read" `Quick test_replacement_during_read_refuses_old_result
      ] ]
;;
