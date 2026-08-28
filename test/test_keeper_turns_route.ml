open Masc

(* GET /api/v1/keepers/turns is what the TUI "answering now" badge polls:
   the running-turn slot lives in the Keeper Owner (process memory), so the
   durable meta the TUI's keeper list is read from cannot answer it.

   Two facts, each pinned at its own layer, in the house style of
   test_rest_approvals_because:

   - routing: the HTTP/1 dashboard router binds ["/api/v1/keepers/turns"]
     to the turns listing handler;
   - serialization: an installed keeper comes back as one row with
     [status = "ok"] and [turn = null] while no turn runs, and an empty
     workspace answers the schema with an empty fleet rather than an
     error. *)

let read_file path =
  let path =
    if Filename.is_relative path then
      match Sys.getenv_opt "DUNE_SOURCEROOT" with
      | Some root -> Filename.concat root path
      | None -> path
    else path
  in
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in_noerr ic;
  s
;;

let test_turns_route_is_registered () =
  let http1 = read_file "lib/server/server_routes_http_routes_dashboard.ml" in
  Alcotest.(check bool)
    "HTTP/1 dashboard router serves the keeper turns listing"
    true
    (String_util.contains_substring http1 "\"/api/v1/keepers/turns\"")
;;

(* Drive the handler the way an HTTP server would: hand its request to a
   Server_connection and collect the response bytes it writes. The write
   result is reported for the full iovec length, not 0 bytes — reporting
   zero would stall the connection's writer and hang the test. *)
let turns_response ~state =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
        Server_routes_http_keeper_stream.handle_keeper_turns_list
          state
          (Httpun.Reqd.request reqd)
          reqd)
  in
  let request = "GET /api/v1/keepers/turns HTTP/1.1\r\nHost: x\r\n\r\n" in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  ignore
    (Httpun.Server_connection.read_eof connection input ~off:0
       ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written =
        List.fold_left
          (fun acc (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string output
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             acc + iov.len)
          0 iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok written);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  Buffer.contents output
;;

let body_of response =
  match Str.bounded_split (Str.regexp "\r\n\r\n") response 2 with
  | [ _; body ] -> body
  | _ -> Alcotest.failf "no body separator in response: %S" response
;;

let with_test_state f =
  let dir = Filename.temp_file "keeper-turns" ".dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace_utils.default_config dir in
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
    (fun () ->
      let request_authority =
        match
          Server_request_authority.of_host_port ~host:"localhost" ~port:8935
        with
        | Ok authority -> authority
        | Error `Malformed -> Alcotest.fail "test authority must be valid"
      in
      Server_request_authority.with_current request_authority (fun () ->
          ignore (Workspace.init config ~agent_name:None);
          let state = Mcp_server_eio.For_testing.create_state ~base_path:dir () in
          f ~sw ~config ~state))
;;

let member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let test_empty_workspace_answers_an_empty_fleet () =
  with_test_state (fun ~sw:_ ~config:_ ~state ->
      let body = body_of (turns_response ~state) in
      let json = Yojson.Safe.from_string body in
      (match member "schema" json with
       | Some (`String "masc.keeper_turns.v1") -> ()
       | other ->
         Alcotest.failf "unexpected schema field: %s"
           (match other with
            | Some value -> Yojson.Safe.to_string value
            | None -> "absent"));
      match member "keepers" json with
      | Some (`List []) -> ()
      | Some (`List rows) ->
        Alcotest.failf "expected no rows, got %d" (List.length rows)
      | _ -> Alcotest.fail "keepers field absent or mistyped")
;;

let test_installed_keeper_rides_as_an_idle_row () =
  with_test_state (fun ~sw ~config ~state ->
      let keeper_name = "turns-route-keeper" in
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ ("name", `String keeper_name)
              ; ("trace_id", `String "trace-keeper-turns-route")
              ; ("autoboot_enabled", `Bool false)
              ])
        with
        | Ok meta -> meta
        | Error err -> Alcotest.fail err
      in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> Alcotest.failf "persist keeper meta: %s" err);
      (match
         Keeper_owner_registry.install_from_store
           ~sw
           ~operation_runner:None
           ~on_turn_slot_released:None
           config
       with
       | Ok count -> Alcotest.(check int) "installed owner count" 1 count
       | Error error ->
         Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
      let body = body_of (turns_response ~state) in
      let json = Yojson.Safe.from_string body in
      match member "keepers" json with
      | Some (`List [ row ]) ->
        (match member "keeper_name" row with
         | Some (`String name) ->
           Alcotest.(check string) "row names the keeper" keeper_name name
         | _ -> Alcotest.fail "row carries no keeper_name");
        (match member "status" row with
         | Some (`String "ok") -> ()
         | other ->
           Alcotest.failf "expected ok status, got %s"
             (match other with
              | Some value -> Yojson.Safe.to_string value
              | None -> "absent"));
        (match member "turn" row with
         | Some `Null -> ()
         | Some value ->
           Alcotest.failf "expected no running turn, got %s"
             (Yojson.Safe.to_string value)
         | None -> Alcotest.fail "row carries no turn field")
      | Some (`List rows) ->
        Alcotest.failf "expected one row, got %d" (List.length rows)
      | _ -> Alcotest.fail "keepers field absent or mistyped")
;;

let () =
  Alcotest.run "keeper_turns_route"
    [ ( "keeper-turns-route"
      , [ Alcotest.test_case "route is registered" `Quick
            test_turns_route_is_registered
        ; Alcotest.test_case "empty workspace answers an empty fleet" `Quick
            test_empty_workspace_answers_an_empty_fleet
        ; Alcotest.test_case "an installed keeper rides as an idle row" `Quick
            test_installed_keeper_rides_as_an_idle_row
        ] )
    ]
;;
