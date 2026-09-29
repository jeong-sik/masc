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

let with_state f =
  with_dir "mcp-seat-" (fun base_path ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Masc_test_deps.init_eio_clock env;
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let state = Mcp_eio.For_testing.create_state ~base_path () in
        f (fun ?(profile = Mcp_eio.Seat) body ->
          Mcp_eio.handle_request ~clock ~sw ~profile state body))))

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
  with_state (fun handle ->
    check (list string) "the seat lists the CanPlayMachine tools" seat_tools
      (tool_names (handle (request "tools/list")));
    let full = tool_names (handle ~profile:Mcp_eio.Full (request "tools/list")) in
    check bool "the full door lists more than the seat" true
      (List.length full > List.length seat_tools))

let test_the_handshake_advertises_tools_only () =
  with_state (fun handle ->
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
  with_state (fun handle ->
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
  with_state (fun handle ->
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
        let seat ?token () =
          passes (Server_auth.verify_seat_mcp_auth ~base_path (http_request ?token "/mcp/play"))
        in
        let full ?token () =
          passes (Server_auth.verify_mcp_auth ~base_path (http_request ?token "/mcp"))
        in
        check bool "an invite opens the seat door" true (seat ~token:player ());
        check bool "an invite does not open /mcp" false (full ~token:player ());
        check bool "a worker opens the seat door" true (seat ~token:worker ());
        check bool "a worker opens /mcp" true (full ~token:worker ());
        check bool "no bearer opens neither" false (seat () || full ());
        check bool "a made-up bearer does not open the seat" false (seat ~token:"nope" ()))))

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
        ] )
    ; ( "http"
      , [ test_case "an invite opens the seat door, not /mcp" `Quick
            test_the_seat_door_admits_an_invite_and_the_full_door_does_not
        ; test_case "POST and DELETE are routed, GET is 405" `Quick
            test_the_routes_serve_post_and_delete_but_no_stream
        ] )
    ]
