module Transport = Server_mcp_transport_http

type stream = {
  response : int Eio.Promise.t;
  ended : unit Eio.Promise.t;
  chunks : string list ref;
}

let member_names workspace =
  match Masc.Play_room.read ~base_path:workspace ~now:(Time_compat.now ()) ~before:None with
  | Ok snapshot -> List.map (fun (member : Masc.Play_room.member) -> member.name) snapshot.members
  | Error error -> Alcotest.fail (Masc.Play_room.error_message error)

let contains text needle =
  let rec seek index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || seek (index + 1))
  in
  seek 0

let await clock promise =
  Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await promise)

let await_condition clock predicate =
  Eio.Time.with_timeout_exn clock 3. (fun () ->
    let rec wait () =
      if predicate () then ()
      else begin
        Eio.Time.sleep clock 0.01;
        wait ()
      end
    in
    wait ())

let open_observer ~sw ~clock ~port ~session_id ~token ~instance_id ?play_client () =
  let response, publish_response = Eio.Promise.create () in
  let ended, publish_ended = Eio.Promise.create () in
  let chunks = ref [] in
  let play_fields = match play_client with
    | None -> []
    | Some play_client -> ["play_machine", "msx"; "play_client_id", play_client]
  in
  let url =
    Uri.add_query_params'
      (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/mcp" port))
      (("sse_kind", "observer") :: play_fields)
    |> Uri.to_string
  in
  let headers =
    [ "Accept", "text/event-stream"; "Mcp-Session-Id", session_id
    ; "Authorization", "Bearer " ^ token; "x-masc-sse-instance-id", instance_id ]
  in
  Eio.Fiber.fork ~sw (fun () ->
    ignore (Masc_http_client.get_stream ~clock ~idle_timeout_sec:3. ~url ~headers
      ~on_response:(fun ~status ~headers:_ ->
        ignore (Eio.Promise.try_resolve publish_response status))
      ~on_chunk:(fun chunk -> chunks := chunk :: !chunks) ());
    Eio.Promise.resolve publish_ended ());
  { response; ended; chunks }

let with_server env ~handler body =
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let socket = Eio.Net.listen ~reuse_addr:true ~backlog:8 ~sw
      (Eio.Stdenv.net env) (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "the test listens on TCP"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label:"play observer fixture"
        ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
          handler gluten_reqd.Gluten.Reqd.reqd);
      `Stop_daemon);
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () -> body ~port)))

let with_fixture env ?(ready = fun () -> true) fn =
  let previous = Sys.getenv_opt "MASC_SSE_RECONNECT_MIN_INTERVAL_S" in
  Unix.putenv "MASC_SSE_RECONNECT_MIN_INTERVAL_S" "0";
  let workspace = Masc_test_deps.setup_test_workspace () in
  let session_id = "play-observer-race-" ^ string_of_int (Random.bits ()) in
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some value -> Unix.putenv "MASC_SSE_RECONNECT_MIN_INTERVAL_S" value
       | None -> Unix.unsetenv "MASC_SSE_RECONNECT_MIN_INTERVAL_S");
      Eio.Cancel.protect (fun () -> Transport.stop_sse_session session_id);
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> Eio.Switch.run (fun sw ->
      let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
        | Ok authority -> authority | Error `Malformed -> Alcotest.fail "fixture authority" in
      let admit ~base_path:_ _request = Ok () in
      let runtime : Transport.runtime =
        { base_path = workspace
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; tool_allowed_in_profile = (fun _ _ -> true)
        ; handle_request =
            (fun ?profile:_ ?mcp_session_id:_ ?otel_mcp_protocol_version:_
                 ?otel_transport_context:_ ?auth_token:_ ?internal_keeper_runtime:_ _ -> `Null)
        ; clear_resource_subscriptions_for_session = (fun _ -> ())
        } in
      let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
      let scope = Masc.Mcp_server.workspace_scope state in
      let previous_authority = Masc.Sse.runtime_authority_exn ~base_path:scope.config.base_path in
      let instance_id = Masc.Build_identity.runtime_instance_id ^ "."
        ^ Masc.Mcp_server.Workspace_scope_epoch.to_string scope.epoch in
      ignore (Masc.Sse.observer_scope ~runtime_authority:previous_authority ~instance_id);
      let deps : Transport.deps =
        { get_origin = (fun _ -> "")
        ; cors_headers = (fun _ -> [])
        ; auth_token_from_request = (fun _ -> None)
        ; is_ready = ready
        ; get_runtime_result = (fun () -> Ok runtime)
        ; get_base_path = (fun () -> workspace)
        ; get_server_state = (fun () -> Some state)
        ; verify_mcp_auth = admit
        ; verify_mcp_observer_stream_auth = admit
        ; verify_operator_mcp_auth = admit
        ; verify_seat_mcp_auth = admit
        } in
      let handler reqd =
        let request = Httpun.Reqd.request reqd in
        Server_request_authority.with_current authority (fun () ->
          Transport.handle_get_mcp ~deps ~sse_kind:Masc.Sse.Observer request reqd) in
      let auth = Masc_test_deps.make_sse_auth workspace "play-observer" in
      let token = Option.get auth.Masc.Sse.token in
      ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
      with_server env ~handler (fun ~port ->
        fn ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock:(Eio.Stdenv.clock env))))
