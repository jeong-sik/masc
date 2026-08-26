open Masc

(* task-345 evidence: the REST approvals listing actually serializes
   [because].

   The verifier's third rejection snapshot was taken at 85c7e81616, before
   the force-push; the branch tip (rebased onto origin/main as 98acacad99)
   answers all three findings. This test pins the one that had no coverage
   anywhere: that GET /api/v1/keepers/tool-approvals — the only place an
   operator sees why a call was held — emits [because] in its rows.

   Two facts, each pinned at its own layer, in the house style of
   test_dashboard_http_core's route-registration tests:

   - routing: the HTTP/1 dashboard router binds
     ["/api/v1/keepers/tool-approvals"] to the listing handler;
   - serialization: a wait parked in the shared registry — the same way a
     keeper turn parks one — comes back out carrying [because] in the
     handler's own response bytes, driven through a Server_connection the
     way the test dashboard drives handlers. *)

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

let test_approvals_route_is_registered () =
  let http1 = read_file "lib/server/server_routes_http_routes_dashboard.ml" in
  Alcotest.(check bool)
    "HTTP/1 dashboard router serves the tool-approvals listing"
    true
    (String_util.contains_substring http1 "\"/api/v1/keepers/tool-approvals\"")
;;

(* Drive the handler the way an HTTP server would: hand its request to a
   Server_connection and collect the response bytes it writes. The write
   result is reported for the full iovec length, not 0 bytes — reporting
   zero would stall the connection's writer and hang the test. *)
let approvals_response ~state =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
        Server_routes_http_keeper_stream.handle_keeper_tool_approvals_list
          state
          (Httpun.Reqd.request reqd)
          reqd)
  in
  let request = "GET /api/v1/keepers/tool-approvals HTTP/1.1\r\nHost: x\r\n\r\n" in
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

let test_rest_listing_serializes_because () =
  let dir = Filename.temp_file "task345" ".dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> try Sys.remove (Filename.concat dir "runtime.toml") with _ -> ())
    (fun () ->
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
            let registry = Masc.Keeper_tool_approval_registry.shared () in
            let clock = Eio.Stdenv.clock env in
            Eio.Fiber.both
              (fun () ->
                 ignore
                   (Masc.Keeper_tool_approval_registry.await registry ~clock
                      ~tool_name:"Execute" ~args:"{}"
                      ~question:"Run Execute on git status?"
                      ~because:"fs tools change something outside this turn"
                      ~keeper_name:"keeper.one" ~tool_call_id:"call-because"
                      ~timeout_sec:5.0
                    : Masc.Keeper_tool_approval_registry.outcome))
              (fun () ->
                 let rec wait attempts =
                   if
                     Masc.Keeper_tool_approval_registry.pending registry = []
                     && attempts > 0
                   then begin
                     Eio.Time.sleep clock 0.005;
                     wait (attempts - 1)
                   end
                 in
                 wait 200;
                 let response = approvals_response ~state in
                 let body = body_of response in
                 let json =
                   match Yojson.Safe.from_string body with
                   | json -> json
                   | exception _ ->
                     Alcotest.failf "listing body is not JSON: %S" body
                 in
                 let open Yojson.Safe.Util in
                 let rows = json |> member "pending" |> to_list in
                 Alcotest.(check int) "one held call is listed" 1 (List.length rows);
                 let row =
                   match rows with
                   | [ row ] -> row
                   | _ -> Alcotest.fail "expected exactly one row"
                 in
                 Alcotest.(check string)
                   "the row carries its question"
                   "Run Execute on git status?"
                   (row |> member "question" |> to_string);
                 Alcotest.(check string)
                   "the row carries because — the only place an operator sees why"
                   "fs tools change something outside this turn"
                   (row |> member "because" |> to_string);
                 ignore
                   (Masc.Keeper_tool_approval_registry.settle registry
                      ~keeper_name:"keeper.one" ~tool_call_id:"call-because"
                      Masc.Keeper_tool_approval_registry.Approve
                    : bool)))))
;;

let () =
  let open Alcotest in
  run "rest_approvals_because"
    [ ( "routing"
      , [ test_case "tool-approvals listing route is registered" `Quick
            test_approvals_route_is_registered ] )
    ; ( "listing"
      , [ test_case "rest approvals listing serializes because" `Quick
            test_rest_listing_serializes_because ] )
    ]
;;
