(* RFC play-link-for-the-shared-machine §2.7: /mcp/play is the seat door an
   invited agent plays through. It lets an invite's Player credential in,
   answers the handshake and the CanPlayMachine tools, and nothing else. *)

open Alcotest
module Mcp_eio = Masc.Mcp_server_eio
module Router = Masc.Http_server_eio.Router

let () = Mirage_crypto_rng_unix.use_default ()

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  go path

let with_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let seat_tools =
  [ "masc_dos_pass"; "masc_dos_press"; "masc_dos_screen"; "masc_dos_step"; "masc_dos_type" ]

let request ?(params = `Assoc []) ?(notification = false) method_ =
  Yojson.Safe.to_string
    (`Assoc
        ([ "jsonrpc", `String "2.0"; "method", `String method_; "params", params ]
         @ if notification then [] else [ "id", `Int 7 ]))

let initialize_params =
  `Assoc
    [ "protocolVersion", `String "2025-11-25"
    ; "capabilities", `Assoc []
    ; "clientInfo", `Assoc [ "name", `String "pi"; "version", `String "1.0" ]
    ]

let invite_token base_path =
  let name =
    match Masc.Play_invite.Name.of_string "pi" with
    | Ok name -> name
    | Error msg -> fail msg
  in
  match
    Masc.Play_invite.issue ~base_path ~public_base_url:(Some "http://127.0.0.1:8935")
      ~keeper_names:(Ok []) ~name ~hours:1
  with
  | Ok { Masc.Play_invite.link; _ } ->
    (match String.index_opt link '#' with
     | Some at -> String.sub link (at + 1) (String.length link - at - 1)
     | None -> failf "no token in %s" link)
  | Error _ -> fail "invite issue failed"

(* [For_testing.create_state] turns workspace auth off. With [~auth:true] it is
   turned back on and every request carries an invite's Player token unless
   the caller passes another. *)
let with_state ?(auth = false) f =
  with_dir "mcp-seat-" (fun base_path ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Masc_test_deps.init_eio_clock env;
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let state = Mcp_eio.For_testing.create_state ~base_path () in
        let player =
          if auth then begin
            Auth.save_auth_config base_path
              { Masc_domain.default_auth_config with enabled = true; require_token = true };
            Some (invite_token base_path)
          end
          else None
        in
        f ~base_path (fun ?(profile = Mcp_eio.Seat) ?auth_token body ->
          let auth_token =
            match auth_token with
            | Some token -> Some token
            | None -> player
          in
          Mcp_eio.handle_request ~clock ~sw ~profile ?auth_token state body))))

let error_code response =
  match member "error" response with
  | Some error ->
    (match member "code" error with
     | Some (`Int code) -> Some code
     | _ -> None)
  | None -> None

let method_not_found = Masc.Mcp_error_code.to_wire_code Masc.Mcp_error_code.Method_not_found

let tool_names response =
  match Option.bind (member "result" response) (member "tools") with
  | Some (`List tools) ->
    List.filter_map
      (fun tool ->
        match member "name" tool with
        | Some (`String name) -> Some name
        | _ -> None)
      tools
    |> List.sort String.compare
  | _ -> failf "no tools in %s" (Yojson.Safe.to_string response)

let test_the_seat_lists_only_the_play_tools () =
  with_state (fun ~base_path:_ handle ->
    check (list string) "the seat lists the CanPlayMachine tools" seat_tools
      (tool_names (handle (request "tools/list")));
    let full = tool_names (handle ~profile:Mcp_eio.Full (request "tools/list")) in
    check bool "the full door lists more than the seat" true
      (List.length full > List.length seat_tools))

let test_the_handshake_advertises_tools_only () =
  with_state (fun ~base_path:_ handle ->
    let result =
      match member "result" (handle (request ~params:initialize_params "initialize")) with
      | Some result -> result
      | None -> fail "initialize failed on the seat"
    in
    (match member "capabilities" result with
     | Some (`Assoc fields) ->
       check (list string) "only tools are advertised" [ "tools" ] (List.map fst fields)
     | _ -> fail "no capabilities");
    check (option string) "instructions are the seat's"
      (Some (Masc.Mcp_server_eio_tool_profile.seat_instructions ()))
      (match member "instructions" result with
       | Some (`String text) -> Some text
       | _ -> None);
    let discovered =
      match member "result" (handle (request "server/discover")) with
      | Some result -> result
      | None -> fail "server/discover failed on the seat"
    in
    check bool "discover advertises the same" true
      (member "capabilities" discovered = member "capabilities" result);
    let full =
      match member "result" (handle ~profile:Mcp_eio.Full (request ~params:initialize_params "initialize")) with
      | Some result -> result
      | None -> fail "initialize failed on the full door"
    in
    check bool "the full door still advertises resources" true
      (Option.bind (member "capabilities" full) (member "resources") <> None))

(* Every method the dispatcher answers besides the handshake and tools admits
   any valid credential or none, so the seat has to refuse them itself. *)
let refused_methods =
  [ "resources/list"
  ; "resources/read"
  ; "resources/templates/list"
  ; "resources/subscribe"
  ; "resources/unsubscribe"
  ; "subscriptions/listen"
  ; "prompts/list"
  ; "prompts/get"
  ; "dashboard/hello"
  ; "dashboard/subscribe"
  ; "dashboard/unsubscribe"
  ; "dashboard/ping"
  ; "dashboard/ack"
  ]

let test_the_seat_refuses_every_other_method () =
  with_state (fun ~base_path:_ handle ->
    List.iter
      (fun method_ ->
        check (option int) (method_ ^ " is refused on the seat") (Some method_not_found)
          (error_code (handle (request method_))))
      refused_methods;
    check bool "the full door answers prompts/list" true
      (member "result" (handle ~profile:Mcp_eio.Full (request "prompts/list")) <> None);
    check bool "a refused notification gets no answer" true
      (handle (request ~notification:true "dashboard/ack") = `Null))

let test_the_seat_refuses_a_tool_it_does_not_list () =
  with_state (fun ~base_path:_ handle ->
    let call name =
      handle
        (request
           ~params:(`Assoc [ "name", `String name; "arguments", `Assoc [] ])
           "tools/call")
    in
    let refused = call "masc_status" in
    check (option int) "masc_status is refused" (Some method_not_found) (error_code refused);
    check bool "with the profile's refusal" true
      (String_util.contains_substring (Yojson.Safe.to_string refused)
         "not available on this MCP endpoint");
    check bool "masc_dos_screen passes the profile gate" false
      (String_util.contains_substring (Yojson.Safe.to_string (call "masc_dos_screen"))
         "not available on this MCP endpoint"))

let invalid_params = Masc.Mcp_error_code.to_wire_code Masc.Mcp_error_code.Invalid_params
let auth_error = Masc.Mcp_error_code.to_wire_code Masc.Mcp_error_code.Auth_error

let call_tool ?auth_token handle name =
  handle ?profile:None ?auth_token
    (request ~params:(`Assoc [ "name", `String name; "arguments", `Assoc [] ]) "tools/call")

(* The protocol cases above run with auth off; this one runs as an invitee,
   so the credential store, the catalog permission check and the profile gate
   all see a Player. *)
let test_an_invite_plays_through_the_seat_with_auth_on () =
  with_state ~auth:true (fun ~base_path:_ handle ->
    check (list string) "an invite lists the play tools" seat_tools
      (tool_names (handle (request "tools/list")));
    check (option int) "a made-up bearer is refused" (Some auth_error)
      (error_code (handle ~auth_token:"nope" (request "tools/list")));
    check (option int) "usage telemetry is not shown on the seat" (Some invalid_params)
      (error_code
         (handle (request ~params:(`Assoc [ "include_usage", `Bool true ]) "tools/list")));
    check bool "ping is answered" true (member "result" (handle (request "ping")) <> None);
    check (option int) "masc_status is refused to an invite" (Some method_not_found)
      (error_code (call_tool handle "masc_status"));
    let screen = call_tool handle "masc_dos_screen" in
    check (option int) "masc_dos_screen is not a protocol error" None (error_code screen);
    (* No machine is loaded, so the lane itself answers: the call got past the
       permission check and ran as the invitee. *)
    let call_meta =
      Option.bind (member "result" screen) (member "_meta")
      |> Fun.flip Option.bind (member Masc.Mcp_server.tool_call_meta_key)
    in
    let meta_string key =
      match Option.bind call_meta (member key) with
      | Some (`String value) -> Some value
      | _ -> None
    in
    check (option string) "masc_dos_screen ran as the invitee" (Some "pi") (meta_string "agent_id");
    check (option string) "the lane refused it, not the permission check"
      (Some "workflow_rejection") (meta_string "failure_class"))

let test_an_invite_recovers_only_a_stopped_keepers_controller () =
  let module Lane = Dos_lane in
  let holder = "seat-holder" in
  (* A self-contained COM guest that waits for a BIOS key, then exits. *)
  let program = "\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20" in
  let controller () =
    match Lane.screen () with
    | Ok observation -> observation.Lane.controller
    | Error error -> fail (Lane.error_to_string error)
  in
  List.iter
    (fun running ->
      List.iter
        (fun (name, arguments) ->
          with_state ~auth:true (fun ~base_path handle ->
            let config = Masc.Workspace.default_config base_path in
            let meta =
              match Masc_test_deps.meta_of_json_fixture
                (`Assoc [ "name", `String holder; "activation_mode", `String "manual" ]) with
              | Ok meta -> meta
              | Error detail -> fail detail
            in
            (match Masc.Keeper_meta_store.replace_snapshot config meta with
             | Ok () -> ()
             | Error detail -> fail detail);
            if running then
              ignore (Masc.Keeper_registry.For_testing.register ~base_path holder meta
                : Masc.Keeper_registry.registry_entry);
            Fun.protect
              ~finally:(fun () ->
                Lane.install_activity_observer None;
                Masc.Keeper_registry.For_testing.unregister ~base_path holder;
                let who = match Lane.screen () with
                  | Ok { Lane.controller = Some name; _ } -> name
                  | Ok _ | Error _ -> "cleanup" in
                ignore (Lane.eject ~who ~announce:(fun () -> ()) ()
                  : (unit, Lane.error) result))
              (fun () ->
                Lane.install_activity_observer
                  (Some (fun () -> Machine_configuration.Enabled));
                (match Lane.load ~who:holder
                  ~ledger_dir:(Filename.concat base_path "ledger")
                  ~saves_dir:(Filename.concat base_path "saves")
                  ~checkpoint_dir:(Filename.concat base_path "checkpoints")
                  ~program_name:"wait.com" ~program_bytes:program ~files:[]
                  ~announce:(fun () -> ()) with
                 | Ok _ -> ()
                 | Error error -> fail (Lane.error_to_string error));
                let call ?auth_token () =
                  handle ?auth_token
                    (request ~params:(`Assoc [ "name", `String name; "arguments", arguments ])
                       "tools/call")
                in
                check (option int) "invalid token is refused before recovery" (Some auth_error)
                  (error_code (call ~auth_token:"not-an-invite" ()));
                check (option string) "unauthorized move leaves the controller" (Some holder)
                  (controller ());
                ignore (call_tool handle "masc_dos_screen" : Yojson.Safe.t);
                check (option string) "watching leaves the controller" (Some holder)
                  (controller ());
                let response = call () in
                check (option int) "authorized move reaches the tool" None (error_code response);
                check (option string) (name ^ ": selected controller")
                  (Some (if running then holder else "pi")) (controller ());
                match member "result" response with
                | None -> fail "tools/call produced no result"
                | Some result ->
                  check bool "only a running holder blocks the move" running
                    (member "isError" result = Some (`Bool true)))))
        [ "masc_dos_press", `Assoc [ "keys", `List [ `String "a" ] ]
        ; "masc_dos_type", `Assoc [ "text", `String "a" ]
        ; "masc_dos_step", `Assoc [ "steps", `Int 1 ]
        ; "masc_dos_pass", `Assoc [ "to", `String "pi" ]
        ])
    [ false; true ]

(* RFC play-link-for-the-shared-machine §2.8 over MCP: the gate a Keeper's
   call and the play page's routes run also stands before an MCP client's
   pass. *)
let test_an_invite_passes_only_to_someone_at_the_machine () =
  let module Lane = Dos_lane in
  let program = "\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20" in
  with_state ~auth:true (fun ~base_path handle ->
    Fun.protect
      ~finally:(fun () ->
        Lane.install_activity_observer None;
        let who = match Lane.screen () with
          | Ok { Lane.controller = Some name; _ } -> name
          | Ok _ | Error _ -> "cleanup" in
        ignore (Lane.eject ~who ~announce:(fun () -> ()) () : (unit, Lane.error) result))
      (fun () ->
        Lane.install_activity_observer
          (Some (fun () -> Machine_configuration.Enabled));
        (match Lane.load ~who:"pi"
          ~ledger_dir:(Filename.concat base_path "ledger")
          ~saves_dir:(Filename.concat base_path "saves")
          ~checkpoint_dir:(Filename.concat base_path "checkpoints")
          ~program_name:"wait.com" ~program_bytes:program ~files:[]
          ~announce:(fun () -> ()) with
         | Ok _ -> ()
         | Error error -> fail (Lane.error_to_string error));
        let response =
          handle
            (request
               ~params:(`Assoc [ "name", `String "masc_dos_pass"
                               ; "arguments", `Assoc [ "to", `String "nobody" ] ])
               "tools/call")
        in
        let result = match member "result" response with
          | Some result -> result
          | None -> fail "tools/call produced no result" in
        check bool "a pass to a name not at the machine is an error" true
          (member "isError" result = Some (`Bool true));
        check bool "and says so" true
          (String_util.contains_substring (Yojson.Safe.to_string result) "not at the DOS machine");
        check (option string) "the invite keeps the controller" (Some "pi")
          (match Lane.screen () with
           | Ok observation -> observation.Lane.controller
           | Error error -> fail (Lane.error_to_string error))))

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let http_request ?token ?(meth = `POST) target =
  let headers =
    ("host", "127.0.0.1:8935")
    :: (match token with
        | Some token -> [ "authorization", "Bearer " ^ token ]
        | None -> [])
  in
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) meth target

let passes = function
  | Ok _ -> true
  | Error _ -> false

let test_the_seat_door_admits_an_invite_and_the_full_door_does_not () =
  with_dir "mcp-seat-auth-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
        let player = invite_token base_path in
        let worker =
          match Auth.create_token base_path ~agent_name:"worker1" ~role:Masc_domain.Worker with
          | Ok (token, _) -> token
          | Error err -> fail (Masc_domain.masc_error_to_string err)
        in
        (* The verifiers the transport is handed, not the Server_auth
           functions: a door bound to the wrong verifier fails here. *)
        let deps = Server_routes_http_common.mcp_transport_http_deps () in
        let seat ?token () =
          passes
            (deps.Server_mcp_transport_http.verify_seat_mcp_auth ~base_path
               (http_request ?token "/mcp/play"))
        in
        let full ?token () =
          passes
            (deps.Server_mcp_transport_http.verify_mcp_auth ~base_path
               (http_request ?token "/mcp"))
        in
        check bool "an invite opens the seat door" true (seat ~token:player ());
        check bool "an invite does not open /mcp" false (full ~token:player ());
        check bool "a worker opens the seat door" true (seat ~token:worker ());
        check bool "a worker opens /mcp" true (full ~token:worker ());
        check bool "no bearer opens neither" false (seat () || full ());
        check bool "a made-up bearer does not open the seat" false (seat ~token:"nope" ()))))

let test_the_seat_opens_no_stream () =
  let listen = request "subscriptions/listen" in
  check bool "a listen body on the seat goes to the dispatcher" false
    (Server_mcp_transport_http.serves_subscriptions_listen
       ~profile:Server_mcp_transport_http.Seat listen);
  check bool "the full door serves it as a stream" true
    (Server_mcp_transport_http.serves_subscriptions_listen
       ~profile:Server_mcp_transport_http.Full listen)

let test_the_seat_ends_only_its_own_sessions () =
  let module T = Server_mcp_transport_http in
  let seat_session = "seat-session-test" and full_session = "full-session-test" in
  Fun.protect
    ~finally:(fun () ->
      T.forget_mcp_session seat_session;
      T.forget_mcp_session full_session)
    (fun () ->
      T.remember_mcp_profile seat_session T.Seat;
      T.remember_mcp_profile full_session T.Full;
      let ends id = passes (T.validate_mcp_session_delete_profile ~profile:T.Seat id) in
      check bool "a seat ends its own session" true (ends seat_session);
      check bool "a seat does not end a /mcp session" false (ends full_session);
      check bool "a seat does not end a session it cannot place" false (ends "no-such-session"))

let test_the_routes_serve_post_and_delete_but_no_stream () =
  let router = Server_routes_http_routes_frontend.add_routes ~port:8935 (Router.create ()) in
  let resolves meth =
    match Router.resolve router (http_request ~meth "/mcp/play") with
    | `Matched _ -> "matched"
    | `Method_not_allowed -> "405"
    | `Not_found -> "404"
  in
  check string "POST /mcp/play is routed" "matched" (resolves `POST);
  check string "DELETE /mcp/play is routed" "matched" (resolves `DELETE);
  check string "GET /mcp/play opens no stream" "405" (resolves `GET);
  check bool "/mcp/play takes the MCP origin and version checks" true
    (Server_routes_http_common.is_mcp_transport_request (http_request "/mcp/play"))

let () =
  run "mcp_seat_profile"
    [ ( "protocol"
      , [ test_case "the seat lists only the play tools" `Quick test_the_seat_lists_only_the_play_tools
        ; test_case "the handshake advertises tools only" `Quick test_the_handshake_advertises_tools_only
        ; test_case "the seat refuses every other method" `Quick test_the_seat_refuses_every_other_method
        ; test_case "the seat refuses a tool it does not list" `Quick
            test_the_seat_refuses_a_tool_it_does_not_list
        ; test_case "an invite plays through the seat with auth on" `Quick
            test_an_invite_plays_through_the_seat_with_auth_on
        ; test_case "an invite passes only to someone at the machine" `Quick
            test_an_invite_passes_only_to_someone_at_the_machine
        ; test_case "an invite recovers only a stopped Keeper controller" `Quick
            test_an_invite_recovers_only_a_stopped_keepers_controller
        ] )
    ; ( "http"
      , [ test_case "an invite opens the seat door, not /mcp" `Quick
            test_the_seat_door_admits_an_invite_and_the_full_door_does_not
        ; test_case "POST and DELETE are routed, GET is 405" `Quick
            test_the_routes_serve_post_and_delete_but_no_stream
        ; test_case "the seat opens no stream" `Quick test_the_seat_opens_no_stream
        ; test_case "the seat ends only its own sessions" `Quick
            test_the_seat_ends_only_its_own_sessions
        ] )
    ]
