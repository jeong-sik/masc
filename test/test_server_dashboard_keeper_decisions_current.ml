open Alcotest
open Masc

module Router = Http_server_eio.Router
module Reader = Server_dashboard_keeper_decisions_http

let endpoint = "/api/v1/dashboard/keeper-decisions?limit=10"

let with_loopback_environment f =
  let bindings = ["MASC_HTTP_AUTH_STRICT", "false"; "MASC_HOST", "127.0.0.1";
    "MASC_HTTP_BASE_URL", "http://127.0.0.1:8935"] in
  let before = List.map (fun (key, _) -> key, Sys.getenv_opt key) bindings in
  List.iter (fun (key, value) -> Unix.putenv key value) bindings;
  Fun.protect ~finally:(fun () -> List.iter (fun (key, value) -> match value with
    | Some value -> Unix.putenv key value | None -> Unix.unsetenv key) before) f

let with_router f = with_loopback_environment (fun () -> Eio_main.run (fun env ->
  let previous_fs = Fs_compat.get_fs_opt ()
  and previous_context = Eio_context.snapshot_state ()
  and previous_state = Server_auth.For_testing.snapshot_server_state ()
  and previous_startup = Server_startup_state.snapshot () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous_state;
    Server_startup_state.For_testing.restore previous_startup;
    Eio_context.restore_state previous_context;
    Masc_test_deps.cleanup_test_workspace base_path;
    match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ()) (fun () ->
    (* Fixture watchdog only, not a product timeout or freshness interval. *)
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
          let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
          Executor_pool_ref.For_testing.with_pool pool (fun () ->
            let state = Mcp_server.For_testing.create_state ~base_path in
            let config = Mcp_server.workspace_config state in
            ignore (Workspace.init config ~agent_name:None);
            Server_auth.For_testing.restore_server_state (Some state);
            (match Server_startup_state.mark_state_ready () with
             | Ok () -> () | Error error -> fail (Server_startup_state.state_ready_error_to_string error));
            let router = Server_routes_http_routes_provider_runs.add_routes ~sw (Router.create ()) in
            f ~config ~router)))))))

(* Drive the registered route through HTTPun's actual request and response
   codecs. The client codec also decodes chunked framing; no socket is used. *)
let get router path =
  let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority | Error `Malformed -> fail "invalid fixture authority" in
  let wire = Server_request_authority.with_current authority (fun () ->
    let output = Buffer.create 4096 in
    let server = Httpun.Server_connection.create (fun reqd ->
      Router.dispatch router (Httpun.Reqd.request reqd) (Http_reqd.of_httpun reqd)) in
    let request = "GET " ^ path ^ " HTTP/1.1\r\nHost: 127.0.0.1:8935\r\n\r\n" in
    let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
    ignore (Httpun.Server_connection.read_eof server bytes ~off:0 ~len:(Bigstringaf.length bytes));
    let rec drain () = match Httpun.Server_connection.next_write_operation server with
      | `Write iovecs ->
          let written = List.fold_left (fun n (iov : Bigstringaf.t Httpun.IOVec.t) ->
            Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            n + iov.len) 0 iovecs in
          Httpun.Server_connection.report_write_result server (`Ok written); drain ()
      | `Yield | `Close _ -> () in
    drain (); Buffer.contents output) in
  let client = Httpun.Client_connection.create () in
  let result = ref None in
  let writer = Httpun.Client_connection.request client (Httpun.Request.create `GET path)
      ~error_handler:(fun _ -> fail "HTTP client rejected the route response")
      ~response_handler:(fun response reader ->
        let body = Buffer.create 4096 in
        let rec consume () = Httpun.Body.Reader.schedule_read reader
            ~on_eof:(fun () -> result := Some (Httpun.Status.to_code response.status, Buffer.contents body))
            ~on_read:(fun bytes ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring bytes ~off ~len); consume ()) in
        consume ()) in
  Httpun.Body.Writer.close writer;
  let rec drain_request () = match Httpun.Client_connection.next_write_operation client with
    | `Write iovecs ->
        let written = List.fold_left (fun n (iov : Bigstringaf.t Httpun.IOVec.t) -> n + iov.len) 0 iovecs in
        Httpun.Client_connection.report_write_result client (`Ok written); drain_request ()
    | `Yield | `Close _ -> () in
  drain_request ();
  let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  (match Httpun.Client_connection.next_read_operation client with
   | `Read -> ignore (Httpun.Client_connection.read_eof client bytes ~off:0 ~len:(Bigstringaf.length bytes))
   | `Yield | `Close -> fail "HTTP client could not consume the route response");
  match !result with
  | Some (status, body) -> status, Yojson.Safe.from_string body
  | None -> fail "route returned an incomplete HTTP response"

let seed config =
  let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc [
      "name", `String "current-decision-keeper"; "trace_id", `String "current-decision-trace"]) with
    | Ok meta -> meta | Error detail -> fail detail in
  (match Keeper_meta_store.replace_snapshot config meta with Ok () -> () | Error detail -> fail detail);
  meta

let append config (meta : Keeper_meta_contract.keeper_meta) ~ts choice =
  let path = Keeper_types_support.keeper_decision_log_path config meta.name in
  Keeper_types_support.append_jsonl_line path (`Assoc [
    "event", `String "turn"; "ts_unix", `Float ts; "keeper_name", `String meta.name;
    "choice", `String choice; "outcome", `String "success"])

let choices json = Yojson.Safe.Util.(json |> member "events" |> to_list
  |> List.map (fun event -> event |> member "choice" |> to_string))

let ok_route router path =
  let status, body = get router path in
  check int "actual route is available" 200 status; body

let test_append_is_visible_to_the_same_request_without_a_clock_wait () =
  with_router (fun ~config ~router ->
    let meta = seed config in
    append config meta ~ts:1.0 "earlier decision";
    let direct = match Reader.read_current ~config ~limit:10 with
      | Ok json -> json | Error error -> fail (Reader.read_error_to_string error) in
    check (list string) "original helper reads the durable first row" ["earlier decision"] (choices direct);
    check (list string) "the registered endpoint reads the same row" ["earlier decision"]
      (choices (ok_route router endpoint));
    append config meta ~ts:2.0 "new durable decision";
    (* Same config and query, with no elapsed-time wait, source notification,
       timer advance or manually requested refresh between the two reads. *)
    check (list string) "completed append is present in the very next HTTP response"
      ["new durable decision"; "earlier decision"] (choices (ok_route router endpoint));
    check (list string) "the original limit remains request-bound" ["new durable decision"]
      (choices (ok_route router "/api/v1/dashboard/keeper-decisions?limit=1")))

let test_roster_failure_is_unavailable_and_quiet_repair_is_current () =
  with_router (fun ~config ~router ->
    let meta = seed config in
    append config meta ~ts:1.0 "preserved roster decision";
    ignore (ok_route router endpoint);
    let directory = Workspace.keepers_runtime_dir config in
    let held = directory ^ ".fixture-held" in
    Unix.rename directory held;
    (match Fs_compat.save_file_atomic directory "not a directory" with
     | Ok () -> () | Error detail -> fail detail);
    (match Reader.read_current ~config ~limit:10 with
     | Error (Reader.Roster_unavailable _) -> ()
     | Error (Metadata_unavailable _) | Ok _ -> fail "unreadable roster became a successful feed");
    let status, error = get router endpoint in
    check int "roster error reaches actual HTTP status" 503 status;
    check string "the failed source is explicit" "keeper_roster_unavailable"
      Yojson.Safe.Util.(error |> member "reason" |> to_string);
    check bool "unreadable fleet is not fabricated as empty events" true
      Yojson.Safe.Util.(error |> member "events" = `Null);
    Sys.remove directory;
    Unix.rename held directory;
    check (list string) "raw repair is consumed without a cache clock or event"
      ["preserved roster decision"] (choices (ok_route router endpoint)))

let test_metadata_failures_never_become_successful_empty_feeds () =
  with_router (fun ~config ~router ->
    let meta = seed config in
    append config meta ~ts:1.0 "preserved metadata decision";
    ignore (ok_route router endpoint);
    let path = Keeper_types_profile.keeper_meta_path config meta.name in
    let original = Fs_compat.load_file path in
    List.iter (fun broken ->
      (match Fs_compat.save_file_atomic path broken with Ok () -> () | Error detail -> fail detail);
      (match Reader.read_current ~config ~limit:10 with
       | Error (Reader.Metadata_unavailable {keeper; detail = _}) ->
           check string "typed failure keeps the original roster owner" meta.name keeper
       | Error (Roster_unavailable _) | Ok _ -> fail "unreadable metadata became a successful feed");
      let status, error = get router endpoint in
      check int "metadata failure reaches actual HTTP status" 503 status;
      check string "the unavailable owner remains explicit" meta.name
        Yojson.Safe.Util.(error |> member "keeper_name" |> to_string);
      (match Fs_compat.save_file_atomic path original with Ok () -> () | Error detail -> fail detail);
      check (list string) "raw metadata repair is current on the next request"
        ["preserved metadata decision"] (choices (ok_route router endpoint))) ["{"; "{}"])

let () = run "Current Keeper Decisions HTTP" ["actual route", [
  test_case "append is visible without elapsed-time refresh" `Quick
    test_append_is_visible_to_the_same_request_without_a_clock_wait;
  test_case "roster failure and quiet repair remain explicit" `Quick
    test_roster_failure_is_unavailable_and_quiet_repair_is_current;
  test_case "metadata read/decode failures do not become empty success" `Quick
    test_metadata_failures_never_become_successful_empty_feeds]]
