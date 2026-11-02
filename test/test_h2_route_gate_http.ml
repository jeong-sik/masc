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
    Masc.Board_dispatch.reset_for_test ();
    Masc.Board.reset_global_for_test ();
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

let request_with_headers ?token ~meth client path =
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
          (Ok (H2.Status.to_code response.status, H2.Headers.to_list response.headers, Buffer.contents bytes)))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len); read ()) in
      read ()) in
  H2.Body.Writer.close writer;
  match Eio.Promise.await result with Ok response -> response | Error detail -> fail detail

let request ?token ~meth client path =
  let status, _, body = request_with_headers ?token ~meth client path in
  status, body

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

let test_fusion_workspace_admission () =
  with_gateway ~make_routes:production (fun ~player client ->
    strict None (fun () ->
      let state = match Server_auth.For_testing.snapshot_server_state () with
        | Some state -> state | None -> fail "fixture server has no workspace" in
      let config = Masc.Mcp_server.workspace_config state in
      let base = Unix.realpath config.base_path in
      let root = Unix.realpath (Masc.Workspace.masc_dir config) in
      let target path fields = Uri.with_query (Uri.of_string path) fields |> Uri.to_string in
      let expected = [ "expected_base_path", [ base ]; "expected_masc_root", [ root ] ] in
      let foreign = [ "expected_base_path", [ base ^ "/foreign" ]; "expected_masc_root", [ root ] ] in
      let receipt = Masc.Workspace.read_precondition_admission_header in
      let read path fields = request_with_headers ~token:player ~meth:`GET client (target path fields) in
      Masc_test_deps.Board_test_preparation.prepare ~base_path:base
        ~action:Masc_test_deps.Board_test_preparation.Bootstrap;
      Masc.Board.reset_global_for_test ();
      Masc.Board_dispatch.reset_for_test ();
      Result.get_ok (Masc.Board_dispatch.init_jsonl ~base_path:base
        ~recipient_lookup:Masc.Recipient_lookup.none_declared ());
      let post = match Masc.Board_dispatch.create_post ~author:"fixture" ~content:"original"
          ~post_kind:Masc.Board.System_post () with
        | Ok post -> post
        | Error error -> fail (Masc.Board.Post_publication_failure.to_string error) in
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs" expected in
      check int "bound list succeeds" 200 code;
      check bool "bound list attests workspace" true (List.mem receipt headers);
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs" foreign in
      check int "foreign list is refused before projection" 409 code;
      check bool "foreign list has no admission receipt" false (List.mem receipt headers);
      let code, _, _ = read "/api/v1/dashboard/fusion-runs" [ "expected_base_path", [ base ] ] in
      check int "partial workspace precondition is refused" 400 code;
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs/unknown" expected in
      check int "bound missing detail remains a 404" 404 code;
      check bool "bound detail attests workspace" true (List.mem receipt headers);
      let code, _, _ = read "/api/v1/dashboard/fusion-runs/unknown" foreign in
      check int "foreign detail is refused before lookup" 409 code;
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs" [] in
      check int "unbound legacy list remains available" 200 code;
      check bool "unbound list is not attested" false (List.mem receipt headers);
      let board = "/api/v1/board/" ^ Masc.Board.Post_id.to_string post.id ^ "?format=flat" in
      let board_target fields = Uri.with_query (Uri.of_string board) (("format", ["flat"]) :: fields) |> Uri.to_string in
      let read_board fields = request_with_headers ~meth:`GET client (board_target fields) in
      let code, headers, _ = read_board expected in
      check int "bound Board original is readable" 200 code;
      check bool "bound Board original attests workspace" true (List.mem receipt headers);
      let code, headers, _ = read_board foreign in
      check int "foreign Board original is refused before lookup" 409 code;
      check bool "foreign Board original has no receipt" false (List.mem receipt headers);
      let code, _, _ = read board expected in
      check int "optional reaction actor still rejects the Player token" 403 code;
      let code, _, _ = read board foreign in
      check int "reaction auth refusal still precedes workspace checks" 403 code;
      strict (Some "1") (fun () ->
        let code, _, _ = read_board expected in
        check int "strict mode still requires authentication" 401 code)))

let test_physical_skill_turn_evidence () =
  with_gateway ~make_routes:production (fun ~player client ->
    let state = match Server_auth.For_testing.snapshot_server_state () with
      | Some state -> state | None -> fail "fixture server has no workspace" in
    let config = Masc.Mcp_server.workspace_config state in
    let module Ledger = Masc.Keeper_skill_activation_ledger in
    let fixture = Yojson.Safe.from_file "fixtures/skill-ledger-async-actions.json" in
    let canonical = match Ledger.of_projection_yojson fixture with
      | Ok ledger -> ledger | Error error -> fail (Ledger.decode_error_code error) in
    let origin = Ledger.session_id canonical in
    let origin_dir = Masc.Keeper_fs.keeper_session_dir config (Masc.Keeper_id.Trace_id.to_string origin) in
    Unix.mkdir origin_dir 0o700;
    let activations = Ledger.activations canonical in
    List.iter (fun activation -> match Ledger.record ~config ~trace_id:origin activation with
      | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error)) activations;
    List.iter (fun delivery -> match Ledger.observe_async_result_delivery ~config ~trace_id:origin
        ~expected_activations:activations delivery with
      | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error))
      (Ledger.async_result_deliveries canonical);
    List.iter (fun action -> match Ledger.observe_async_action ~config ~trace_id:origin action with
      | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error)) (Ledger.async_actions canonical);
    let path = "/api/v1/dashboard/skill-activations/physical-turn" in
    let target turn = Uri.with_query (Uri.of_string path) [ "turn_ref", [ turn ] ] |> Uri.to_string in
    let receiving = "new-physical-trace#73" in
    strict None (fun () ->
      let code, body = request ~meth:`GET client path in
      check int "missing reference is a client error, not an unimplemented route" 400 code;
      check string "same missing-reference response as HTTP/1" "turn_ref query param is required"
        Yojson.Safe.Util.(Yojson.Safe.from_string body |> member "error" |> to_string);
      List.iter (fun invalid ->
        check int ("invalid physical turn is refused by the owner: " ^ invalid) 400
          (status ~meth:`GET client (target invalid)))
        [ "not-a-turn"; "trace#0"; "trace#-1"; "   #1" ]);
    strict (Some "1") (fun () ->
      check int "strict Public_read still requires a credential" 401
        (status ~meth:`GET client (target receiving));
      let code, body = request ~token:player ~meth:`GET client (target receiving) in
      check int "authenticated physical lookup is served over H2" 200 code;
      let json = Yojson.Safe.from_string body in
      let expected = match Server_skill_physical_turn.project_string ~config receiving with
        | Ok json -> json | Error detail -> fail detail in
      check bool "same scoped owner projection as HTTP/1" true (Yojson.Safe.equal expected json);
      let open Yojson.Safe.Util in
      check string "exact physical turn survives transport" receiving (json |> member "turn_ref" |> to_string);
      let origins = json |> member "origins" |> to_list in
      check int "finds the cross-trace original ledger" 1 (List.length origins);
      let observed = List.hd origins in
      check int "keeps both physical handoffs" 2
        (observed |> member "async_result_deliveries" |> to_list |> List.length);
      check int "keeps all physical action links" 3
        (observed |> member "async_actions" |> to_list |> List.length);
      let code, body = request ~token:player ~meth:`GET client (target "new-physical-trace#74") in
      check int "adjacent physical turn remains readable" 200 code;
      check int "adjacent turn does not borrow the original's evidence" 0
        (Yojson.Safe.from_string body |> member "origins" |> to_list |> List.length)))

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
        ; test_case "Fusion workspace admission" `Quick test_fusion_workspace_admission
        ; test_case "physical Skill turn evidence" `Quick test_physical_skill_turn_evidence
        ] )
    ]
