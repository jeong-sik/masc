(** The HTTP/2 gateway asks the HTTP/1 router for the kind of each request and runs
    the gate that goes with it. These tests drive the real gateway over an h2c
    connection against the production route table, and against small tables that
    disagree with an arm, which the gateway must refuse. *)

open Alcotest

(* [with_h2_public_read] answers 503 until the server state is marked ready. *)
let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_gateway ~make_routes run =
  let base_path = Filename.temp_dir "h2-route-gate-" "" in
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
        let player =
          match Auth.create_token base_path ~agent_name:"guest" ~role:Masc_domain.Player with
          | Ok (token, _) -> token
          | Error error -> fail (Masc_domain.masc_error_to_string error)
        in
        Server_auth.For_testing.restore_server_state (Some state);
        let trust_policy =
          match
            Server_request_authority.make_trust_policy
              ~bind_host:"localhost" ~bind_port:8935 ~explicit_base_url:None
          with
          | Ok policy -> policy
          | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
        in
        let clock = Eio.Stdenv.clock env in
        let routes = make_routes ~sw ~clock in
        let handler =
          Server_h2_gateway.make_request_handler ~trust_policy ~routes ~sw ~clock
            ~server_start_time:0.
        in
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
          Eio.Flow.shutdown client_flow `All) (fun () -> run ~player client);
        Eio.Promise.await_exn server))

let request ?token ~meth client path =
  let result, resolve = Eio.Promise.create () in
  let headers = [":authority", "localhost:8935"]
    @ (match token with None -> [] | Some token -> ["authorization", "Bearer " ^ token]) in
  let req = H2.Request.create ~scheme:"http" meth path ~headers:(H2.Headers.of_list headers) in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true req
    ~error_handler:(fun _ -> if not (Eio.Promise.is_resolved result) then
      Eio.Promise.resolve resolve (Error "stream failed"))
    ~response_handler:(fun response reader ->
      let bytes = Buffer.create 256 in
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> Eio.Promise.resolve resolve
          (Ok (H2.Status.to_code response.status, Buffer.contents bytes)))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len); read ()) in
      read ()) in
  H2.Body.Writer.close writer;
  match Eio.Promise.await result with Ok response -> response | Error detail -> fail detail

let status ?token ~meth client path = fst (request ?token ~meth client path)

let production ~sw ~clock = Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock

let strict value run =
  Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" value run

(* A route HTTP/1 registers as [Public_read] asks for a credential under strict
   auth. Before the gate read the router, the HTTP/2 arm of the agent card had no
   gate and answered without one. *)
let test_public_read_follows_the_router () =
  with_gateway ~make_routes:production (fun ~player:_ client ->
    strict None (fun () ->
      check int "agent card, default config" 200
        (status ~meth:`GET client "/.well-known/agent.json"));
    strict (Some "1") (fun () ->
      check int "agent card, strict config" 401
        (status ~meth:`GET client "/.well-known/agent.json");
      check int "agent-card.json, strict config" 401
        (status ~meth:`GET client "/.well-known/agent-card.json");
      check int "a route that is Always_public stays open" 200
        (status ~meth:`GET client "/health")))

let test_token_permission_follows_the_router () =
  with_gateway ~make_routes:production (fun ~player client ->
    check int "no credential" 401 (status ~meth:`GET client "/api/v1/lanes");
    check int "a Player token lacks the CanAdmin the router records" 403
      (status ~token:player ~meth:`GET client "/api/v1/lanes"))

(* The keepers prefix is [Subpath_dispatch]: the router holds no kind for its
   sub-routes, so its arms keep their own token check. *)
let test_subpath_arms_keep_their_own_gate () =
  with_gateway ~make_routes:production (fun ~player:_ client ->
    check int "github identity needs a credential" 401
      (status ~meth:`GET client "/api/v1/keepers/someone/github-identity"))

(* [namespace-truth] was an alias only HTTP/2 served. *)
let test_a_path_the_router_lacks_is_not_found () =
  with_gateway ~make_routes:production (fun ~player:_ client ->
    check int "namespace-truth" 404
      (status ~meth:`GET client "/api/v1/dashboard/namespace-truth"));
  with_gateway
    ~make_routes:(fun ~sw:_ ~clock:_ -> Masc.Http_server_eio.Router.create ())
    (fun ~player:_ client ->
      check int "an empty table" 404 (status ~meth:`GET client "/health"));
  with_gateway
    ~make_routes:(fun ~sw:_ ~clock:_ ->
      Masc.Http_server_eio.Router.create ()
      |> Server_route.post Server_route.Always_public "/health" (fun _request _reqd -> ()))
    (fun ~player:_ client ->
      check int "a method the table lacks" 405 (status ~meth:`GET client "/health"))

(* The arm of [/api/v1/lanes] needs an actor. A table that records a kind with no
   actor must not turn the route into an open one. *)
let test_a_table_that_disagrees_with_an_arm_refuses () =
  with_gateway
    ~make_routes:(fun ~sw:_ ~clock:_ ->
      Masc.Http_server_eio.Router.create ()
      |> Server_route.get Server_route.Public_read "/api/v1/lanes"
           (fun _state _request _reqd -> ()))
    (fun ~player:_ client ->
      check int "public_read where the arm needs an actor" 500
        (status ~meth:`GET client "/api/v1/lanes"));
  with_gateway
    ~make_routes:(fun ~sw:_ ~clock:_ ->
      Masc.Http_server_eio.Router.create ()
      |> Server_route.get
           (Server_route.Self_authenticated Masc.Route_access.Subpath_dispatch)
           "/api/v1/lanes"
           (fun _request _reqd -> ()))
    (fun ~player:_ client ->
      check int "a kind HTTP/2 does not serve" 500
        (status ~meth:`GET client "/api/v1/lanes"))

let () =
  run "H2 route gate"
    [ ( "gate"
      , [ test_case "public read follows the router" `Quick test_public_read_follows_the_router
        ; test_case "token permission follows the router" `Quick
            test_token_permission_follows_the_router
        ; test_case "subpath arms keep their own gate" `Quick
            test_subpath_arms_keep_their_own_gate
        ; test_case "a path the router lacks is not found" `Quick
            test_a_path_the_router_lacks_is_not_found
        ; test_case "a table that disagrees with an arm refuses" `Quick
            test_a_table_that_disagrees_with_an_arm_refuses
        ] )
    ]
