open Alcotest
open Masc

let paths = [Server_model_metrics_stream.stream_path;
  Server_tool_metrics_series_stream.stream_path;
  Server_routes_http_routes_log_stream.stream_path]

let with_workspace f =
  let bindings = ["MASC_HTTP_AUTH_STRICT", "false"; "MASC_HOST", "127.0.0.1";
    "MASC_HTTP_BASE_URL", "http://127.0.0.1:8935"] in
  let previous = List.map (fun (name, _) -> name, Sys.getenv_opt name) bindings in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Server_startup_state.snapshot () in
  List.iter (fun (name, value) -> Unix.putenv name value) bindings;
  Fun.protect ~finally:(fun () ->
    List.iter (fun (name, value) -> Unix.putenv name (Option.value value ~default:"")) previous;
    Server_auth.For_testing.restore_server_state previous_state;
    Server_startup_state.For_testing.restore previous_startup) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
        let base_path = Masc_test_deps.setup_test_workspace () in
        Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path) (fun () ->
          Eio.Switch.run (fun sw ->
            let state = Mcp_server.For_testing.create_state ~base_path in
            Server_auth.publish_server_state state;
            (match Server_startup_state.mark_state_ready () with
             | Ok () -> () | Error error -> fail (Server_startup_state.state_ready_error_to_string error));
            let clock = Eio.Stdenv.clock env in
            let router = Http_server_eio.Router.create ()
              |> Server_model_metrics_stream.add_routes ~sw ~clock
              |> Server_tool_metrics_series_stream.add_routes ~sw ~clock
              |> Server_routes_http_routes_log_stream.add_routes ~sw ~clock in
            f ~state ~clock ~router)))))
;;

let request router path headers =
  let output = Buffer.create 2048 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) (Http_reqd.of_httpun reqd)) in
  let fields = List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n") headers
    |> String.concat "" in
  let wire = "GET " ^ path ^ " HTTP/1.1\r\nHost: 127.0.0.1:8935\r\n" ^ fields ^ "\r\n" in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority | Error _ -> fail "invalid test request authority" in
  Server_request_authority.with_current authority (fun () ->
    ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input)));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
        let length = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
          Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
          total + iov.len) 0 iovecs in
        Httpun.Server_connection.report_write_result connection (`Ok length);
        drain ()
    | `Yield -> false
    | `Close _ -> true in
  ignore (drain ());
  let lines = Buffer.contents output |> String.split_on_char '\n' in
  let status = match lines with
    | first :: _ -> (match String.split_on_char ' ' first with
      | _ :: value :: _ -> int_of_string value | _ -> fail "invalid status")
    | [] -> fail "missing response" in
  let header name = List.find_map (fun line -> match String.index_opt line ':' with
    | Some split when String.equal (String.lowercase_ascii (String.sub line 0 split)) name ->
        Some (String.trim (String.sub line (split + 1) (String.length line - split - 1)))
    | Some _ | None -> None) lines in
  status, header, drain
;;

let replace state = match Mcp_server.set_workspace_config state (Mcp_server.workspace_config state) with
  | Ok () -> () | Error _ -> fail "same-path workspace replacement failed"
;;

let test_all_routes_require_original_instance () = with_workspace (fun ~state ~clock:_ ~router ->
  let original = Server_observer_scope.instance_id (Mcp_server.workspace_scope state) in
  List.iter (fun path ->
    let status, _, _ = request router path [] in
    check int (path ^ " requires original scope") 400 status;
    let status, _, _ = request router path [Sse_wire.instance_header, original;
      Sse_wire.instance_header, original] in
    check int (path ^ " refuses duplicate scope") 400 status;
    let status, _, _ = request router path [Sse_wire.instance_header, "foreign-instance"] in
    check int (path ^ " refuses foreign scope") 409 status) paths;
  replace state;
  List.iter (fun path ->
    let status, _, _ = request router path [Sse_wire.instance_header, original] in
    check int (path ^ " refuses retired same-path scope") 409 status) paths)
;;

let test_admitted_streams_attest_and_retire () = with_workspace (fun ~state ~clock ~router ->
  let original = Server_observer_scope.instance_id (Mcp_server.workspace_scope state) in
  let streams = List.map (fun path ->
    let status, header, drain = request router path [Sse_wire.instance_header, original; "origin", "http://127.0.0.1:8935"] in
    check int (path ^ " admits original scope") 200 status;
    check (option string) (path ^ " attests original scope") (Some original) (header Sse_wire.instance_header);
    check (option string) (path ^ " preserves admitted browser origin")
      (Some "http://127.0.0.1:8935") (header "access-control-allow-origin");
    let exposed = Option.value ~default:"" (header "access-control-expose-headers")
      |> String.lowercase_ascii |> String.split_on_char ',' |> List.map String.trim in
    check bool (path ^ " exposes its scope attestation") true (List.mem Sse_wire.instance_header exposed);
    check bool (path ^ " exposes the advertised byte deadline") true
      (List.mem Server_mcp_transport_http_headers.observer_idle_timeout_header exposed);
    path, drain) paths in
  replace state;
  Eio.Time.with_timeout_exn clock 2. (fun () ->
    List.iter (fun (_path, drain) ->
      let rec closed () = if not (drain ()) then (Eio.Fiber.yield (); closed ()) in
      closed ()) streams);
  check int "retired model query has no source subscription" 0
    (Sse.external_subscriber_count_with_prefix "model-metrics:");
  check int "retired tool query has no source subscription" 0
    (Sse.external_subscriber_count_with_prefix "tool-series:"))
;;

let test_scope_owner_cannot_borrow_the_current_scope () = with_workspace (fun ~state ~clock:_ ~router:_ ->
  let original = Server_observer_scope.instance_id (Mcp_server.workspace_scope state) in
  let request = Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [Sse_wire.instance_header, original]) `GET "/native" in
  let owner = match Server_observer_scope.admit_stream ~state request with
    | Ok owner -> owner | Error _ -> fail "original owner was refused" in
  replace state;
  check bool "original owner is retired before any new owner activation" false
    (Server_observer_scope.stream_is_current owner);
  check string "captured owner never borrows replacement instance" original
    (Server_observer_scope.stream_instance owner);
  Server_observer_scope.await_stream_replaced owner)
;;

let () = run "native query original observer scope" ["authority", [
  test_case "all three actual routes require original scope" `Quick test_all_routes_require_original_instance;
  test_case "admitted streams attest and retire" `Quick test_admitted_streams_attest_and_retire;
  test_case "captured owner survives no same-path replacement" `Quick test_scope_owner_cannot_borrow_the_current_scope]]
