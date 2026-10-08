open Alcotest

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_gateway run =
  let base_path = Filename.temp_dir "h2-play-room-" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous_state;
    remove_tree base_path) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
      (fun () ->
        let state = Masc.Mcp_server.For_testing.create_state ~base_path in
        ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config state) ~agent_name:None);
        Auth.save_auth_config base_path
          { Masc_domain.default_auth_config with enabled = true; require_token = true };
        let token = match Auth.create_token base_path ~agent_name:"guest" ~role:Masc_domain.Player with
          | Ok (token, _) -> token
          | Error error -> fail (Masc_domain.masc_error_to_string error) in
        Server_auth.For_testing.restore_server_state (Some state);
        let trust_policy = match Server_request_authority.make_trust_policy
          ~bind_host:"localhost" ~bind_port:8935 ~explicit_base_url:None with
          | Ok policy -> policy
          | Error error -> fail (Server_request_authority.trust_policy_error_to_string error) in
        let handler = Server_h2_gateway.make_request_handler ~trust_policy ~sw
          ~clock:(Eio.Stdenv.clock env) ~server_start_time:0. in
        let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
        let server = Eio.Fiber.fork_promise ~sw (fun () ->
          Eio.Switch.run @@ fun conn_sw ->
          Server_bootstrap_http.serve_h2_connection ~sw:conn_sw
            ~h2_request_handler:handler
            ~h2_error_handler:(Server_h2_gateway.make_error_handler ())
            (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow) in
        let closing = ref false in
        let client = H2_eio.Client.create_connection ~sw
          ~error_handler:(fun _ -> if not !closing then fail "H2 connection error") client_flow in
        Fun.protect ~finally:(fun () ->
          closing := true;
          Eio.Flow.shutdown client_flow `All) (fun () -> run ~base_path ~token client);
        Eio.Promise.await_exn server))

let request ?token ?(body = "") ~meth client path =
  let result, resolve = Eio.Promise.create () in
  let headers = [":authority", "localhost:8935"; "content-type", "application/json"]
    @ (match token with None -> [] | Some token -> ["authorization", "Bearer " ^ token]) in
  let req = H2.Request.create ~scheme:"http" meth path ~headers:(H2.Headers.of_list headers) in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true req
    ~error_handler:(fun _ -> if not (Eio.Promise.is_resolved result) then
      Eio.Promise.resolve resolve (Error "stream failed"))
    ~response_handler:(fun response reader ->
      let bytes = Buffer.create 256 in
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> Eio.Promise.resolve resolve
          (Ok (H2.Status.to_code response.status, Yojson.Safe.from_string (Buffer.contents bytes))))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len); read ()) in
      read ()) in
  H2.Body.Writer.write_string writer body;
  H2.Body.Writer.close writer;
  match Eio.Promise.await result with Ok response -> response | Error detail -> fail detail

let test_room_routes () = with_gateway (fun ~base_path ~token client ->
  let path = Server_routes_http_routes_play_room.path in
  List.iter (fun meth ->
    let status, _ = request ~meth ~body:"{}" client path in
    check int "room requires a credential on H2" 401 status) [`GET; `POST];
  let status, json = request ~token ~meth:`GET client path in
  check int "room read reaches H2 handler" 200 status;
  let expected = Server_routes_http_routes_play_room.read ~base_path
    (Httpun.Request.create `GET path)
    |> Server_routes_http_routes_play_room.response ~viewer:"guest" |> snd in
  check string "H2 uses the shared viewer projection"
    (Yojson.Safe.to_string expected) (Yojson.Safe.to_string json);
  let body = {|{"action":"say","client_id":"tab-a","machine":"dos","message_id":"once","text":"hello from H2"}|} in
  let status, _ = request ~token ~meth:`POST ~body client path in
  check int "room write reaches H2 handler" 200 status;
  let status, _ = request ~token ~meth:`POST ~body client path in
  check int "retry keeps same idempotent receipt" 200 status;
  let snapshot = match Masc.Play_room.read ~base_path ~now:(Time_compat.now ()) ~before:None with
    | Ok snapshot -> snapshot | Error error -> fail (Masc.Play_room.error_message error) in
  check int "one durable message after retry" 1 (List.length snapshot.messages);
  let message = List.hd snapshot.messages in
  check string "authenticated actor owns message" "guest" message.who;
  check string "body preserved" "hello from H2" message.text;
  let status, _ = request ~token ~meth:`GET client (path ^ "?before=0") in
  check int "shared query validation" 400 status;
  let status, _ = request ~token ~meth:`POST ~body:"not json" client path in
  check int "shared body validation" 400 status)

let () = run "H2 Play room" ["routes", [test_case "read, write, auth and validation" `Quick test_room_routes]]
