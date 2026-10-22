(** The browser-lane transport routes a native host calls, through the real
    router: [/browser-lane/ping] answers only the workspace's lane token and
    registers no browser client. The host moves to an address only after
    this route answers it, so a ping that registered a client would leave a
    connected-looking browser on a server the host never polls. *)

open Alcotest
module Http = Masc.Http_server_eio

let token = "browser-lane-route-test-token"
let client_id = "50000000-0000-4000-8000-000000000001"

let with_workspace f =
  let base = Filename.temp_dir "masc-browser-lane-routes-" "" in
  let lane = List.fold_left Filename.concat base [ ".masc"; "browser-lane" ] in
  let token_file = Filename.concat lane "token" in
  let previous=Sys.getenv_opt Env_config_core.base_path_env_key in
  (* Authentication must use the served workspace, even when the process's
     environment points somewhere else. *)
  Unix.putenv Env_config_core.base_path_env_key (base ^ "-not-served");
  let rec remove path=match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
    | _ -> Unix.unlink path in
  Fun.protect
    ~finally:(fun () ->
      (match previous with Some value -> Unix.putenv Env_config_core.base_path_env_key value
       | None -> Unix.unsetenv Env_config_core.base_path_env_key);
      remove base)
    (fun () -> f ~config:(Masc.Workspace.default_config base) ~lane ~token_file)

let post router ~path ~headers =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
  in
  let header_lines =
    String.concat "" (List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n") headers)
  in
  let raw_request =
    "POST " ^ path ^ " HTTP/1.1\r\nHost: localhost\r\n" ^ header_lines
    ^ "Content-Length: 0\r\n\r\n"
  in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             total + iov.len)
          0 iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok bytes);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  let raw = Buffer.contents output in
  let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
  let rec body_offset index =
    if index + 4 > String.length raw then fail ("no HTTP body: " ^ raw)
    else if String.sub raw index 4 = "\r\n\r\n" then index + 4
    else body_offset (index + 1)
  in
  let offset = body_offset 0 in
  status, Yojson.Safe.from_string (String.sub raw offset (String.length raw - offset))

let ping router ~headers = post router ~path:"/browser-lane/ping" ~headers

let host_headers presented =
  [ "x-lane", "live"; "x-lane-token", presented; "x-browser-client-id", client_id
  ; "x-browser-name", "firefox"; "x-browser-version", "155.0"
  ; "x-browser-engine-version", "155.0"; "x-browser-transport", "web_extension" ]

let test_discovery_distinguishes_transports_of_the_same_browser () =
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let decode headers =
    let request = Httpun.Request.create
      ~headers:(Httpun.Headers.of_list headers) `POST "/browser-lane/poll" in
    Server_routes_http_routes_browser_lane.client_of_request request
  in
  let register ?transport id =
    let headers = host_headers token
      |> List.remove_assoc "x-browser-client-id"
      |> List.remove_assoc "x-browser-transport" in
    let headers = ("x-browser-client-id", id) :: headers in
    let headers = match transport with None -> headers
      | Some transport -> ("x-browser-transport", transport) :: headers in
    let info = match decode headers with
      | Ok info -> info | Error detail -> fail detail in
    (match Browser_lane.register info with
     | Ok _ -> ()
     | Error refusal -> fail (Browser_lane.registration_refusal_to_wire refusal));
    Eio.Switch.on_release sw (fun () ->
      ignore (Browser_lane.disconnect_client ~client_id:info.client_id));
    info
  in
  let extension = register ~transport:"web_extension" "50000000-0000-4000-8000-000000000002" in
  let bidi = register ~transport:"webdriver_bidi" "50000000-0000-4000-8000-000000000003" in
  let installed = register "50000000-0000-4000-8000-000000000004" in
  check bool "installed extension host keeps polling after the server upgrade" true
    (installed.transport = Browser_lane.Web_extension);
  check bool "explicit extension declaration keeps the installed client identity" true
    (Result.is_ok (Browser_lane.register {installed with transport=Browser_lane.Web_extension}));
  let clients = Browser_lane.active_clients () |> List.map Browser_lane.client_json in
  let bidi_ids = List.filter_map (fun json ->
    let open Yojson.Safe.Util in
    if (json |> member "transport") = `String "webdriver_bidi"
    then Some (json |> member "clientId" |> to_string) else None) clients in
  check (list string) "discovery selects the BiDi client despite identical Firefox versions"
    [Browser_lane.client_id_to_string bidi.client_id] bidi_ids;
  check bool "a client id cannot change transport" true
    (Browser_lane.register {extension with transport=Browser_lane.Webdriver_bidi}
     = Error Browser_lane.Client_identity_changed);
  check bool "empty transport is rejected" true
    (Result.is_error (decode (("x-browser-transport", "") ::
      List.remove_assoc "x-browser-transport" (host_headers token))));
  check bool "unknown transport is not guessed" true
    (Result.is_error (decode (("x-browser-transport", "other") ::
      List.remove_assoc "x-browser-transport" (host_headers token))))

let test_ping_answers_only_the_lane_token_and_registers_no_client () =
  with_workspace @@ fun ~config ~lane ~token_file ->
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let router = Server_routes_http_routes_browser_lane.add_routes ~config (Http.Router.create ()) in
  let status, _ = ping router ~headers:(host_headers token) in
  check int "a workspace without a lane token answers no ping" 403 status;
  List.iter (fun dir -> Sys.mkdir dir 0o700)
    [ Filename.dirname lane; lane ];
  Out_channel.with_open_bin token_file (fun channel -> output_string channel token);
  let status, _ = ping router ~headers:(host_headers "another-workspace-lane-token") in
  check int "another workspace's token is refused" 403 status;
  let status, body = ping router ~headers:(host_headers token) in
  check int "the lane token is answered" 200 status;
  check bool "the answer is the acknowledgement a host reads" true
    (body = `Assoc [ "ok", `Bool true ]);
  check bool "answering registers no browser client" true (Browser_lane.active_clients () = [])

(* Authenticated native traffic goes only to an Add-on. A process-local
   built-in client cannot receive it, and retained IDs cannot be rebound. *)
let test_native_ingress_has_no_builtin_fallback () =
  with_workspace @@ fun ~config ~lane ~token_file ->
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let router=Server_routes_http_routes_browser_lane.add_routes ~config (Http.Router.create ()) in
  List.iter (fun dir -> Unix.mkdir dir 0o700) [Filename.dirname lane;lane];
  Out_channel.with_open_bin token_file (fun out -> output_string out token);
  let headers=host_headers token in
  let client=match Server_routes_http_routes_browser_lane.client_of_request
    (Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `POST "/browser-lane/poll") with
    | Ok client -> client | Error detail -> fail detail in
  (match Browser_lane.register client with Ok _ -> ()
   | Error refusal -> fail (Browser_lane.registration_refusal_to_wire refusal));
  Eio.Switch.on_release sw (fun () -> ignore (Browser_lane.disconnect_client ~client_id:client.client_id));
  let listing=Server_routes_http_browser_surface.clients_listing ~config in
  check bool "Dashboard inventory does not borrow builtin clients" true
    (Tool_result.failure_class listing=Some Tool_result.Dependency_unavailable);
  let refusal_code body = Yojson.Safe.Util.(member "error" body |> to_string) in
  let status,body=post router ~path:"/browser-lane/poll" ~headers in
  check int "builtin connection does not substitute for an absent Add-on" 503 status;
  check string "an absent Add-on is named by a code the host logs" "no_browser_addon" (refusal_code body);
  check bool "a sentence for the operator rides beside the code" true
    (Yojson.Safe.Util.(member "detail" body |> to_string) <> "");
  let root=Filename.concat lane "registrations" in
  let recorded=Masc.Browser_addon_registration.claim ~root ~client
    ~instance_id:"0b000000-0000-4000-8000-000000000001" in
  (match recorded with Ok _ -> () | Error Identity_changed -> fail "identity changed"
   | Error (Unconfirmed detail) -> fail detail);
  let status,body=post router ~path:"/browser-lane/poll" ~headers in
  check int "missing inventory is unavailable rather than proof of retirement" 503 status;
  check string "an Add-on that is not running is a different cause" "browser_addon_unavailable" (refusal_code body);
  let changed=("x-browser-transport","webdriver_bidi")::List.remove_assoc "x-browser-transport" headers in
  let status,body=post router ~path:"/browser-lane/poll" ~headers:changed in
  check int "retained client identity cannot be changed" 400 status;
  check bool "identity conflict remains distinct from retirement" true
    (body=`Assoc ["ok",`Bool false;"error",`String "client_identity_changed"])

let test_unavailable_causes_have_host_readable_distinct_codes () =
  let module I = Masc.Browser_addon_ingress in
  let causes = [ I.No_addon; I.Ambiguous_addons; I.Observation_unavailable; I.Addon_unavailable;
                 I.Registration_unconfirmed "detail"; I.Worker_unavailable "detail";
                 I.Worker_refused "detail" ] in
  let codes = List.map I.unavailable_to_wire causes in
  check int "each cause has its own code" (List.length causes)
    (List.length (List.sort_uniq String.compare codes));
  List.iter (fun code ->
    check bool ("the host keeps " ^ code) true (Browser_host.is_refusal_code code))
    codes;
  check bool "a payload is a diagnostic, not part of the code" true
    (I.unavailable_to_wire (I.Worker_refused "one") = I.unavailable_to_wire (I.Worker_refused "two"))

let test_owned_pointer_poll_retains_command_and_settles_waiter () =
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let id = match Browser_lane.client_id_of_string "50000000-0000-4000-8000-000000000008" with
    | Ok id -> id | Error detail -> fail detail in
  let info : Browser_lane.client_info = {client_id=id;browser=Firefox;version="158.0";
    engine_version="158.0";transport=Webdriver_bidi} in
  let client = match Browser_lane.register info with
    | Ok client -> client | Error refusal -> fail (Browser_lane.registration_refusal_to_wire refusal) in
  Eio.Switch.on_release sw (fun () -> ignore (Browser_lane.disconnect_client ~client_id:id));
  let point x y : Browser_lane.Pointer.point = {x;y} in
  let viewport : Browser_lane.Pointer.viewport = {document_id="fixture-document";
    width=800.;height=600.;scroll_x=0.;scroll_y=0.} in
  let hovered = Browser_lane.Page_interact {frame_path=[];tab_id=4;expected_url=Some "https://example.test/";
    action=Hover_at {point=point 0.3 0.4;viewport}} in
  let dragged = Browser_lane.Page_interact {frame_path=[];tab_id=4;expected_url=Some "https://example.test/";
    action=Drag {from=point 0.3 0.4;to_=point 0.7 0.8;viewport;via=[];duration_ms=0}} in
  List.iter (fun (actor,verb) ->
    let waiting = Eio.Fiber.fork_promise ~sw (fun () ->
      Browser_lane.issue_live_with ~activity_check:(fun _ -> None) ?actor client ~verb ~timeout_sec:1.) in
    let issued = match Browser_lane.take_command ~client_info:info ~window_sec:1. with
      | Ok (Some issued) -> issued
      | Ok None -> fail "owned command was not queued"
      | Error refusal -> fail (Browser_lane.registration_refusal_to_wire refusal) in
    (* Field order is deliberately varied after exercising the real producer. *)
    let expected = Yojson.Safe.Util.member "args" (Browser_lane.verb_json verb) in
    List.iter (fun issued ->
      let polled = Server_routes_http_routes_browser_lane.poll_answer_json issued in
      let open Yojson.Safe.Util in
      check string "poll preserves request ownership" issued.Browser_lane.id (polled |> member "id" |> to_string);
      check string "poll forwards the real verb" (Browser_lane.verb_json verb |> member "verb" |> to_string)
        (polled |> member "verb" |> to_string);
      check bool "poll preserves pointer/read arguments" true (polled |> member "args" = expected);
      check (option string) "poll forwards optional Keeper actor" actor
        (match polled |> member "actor" with `Null -> None | value -> Some (to_string value)))
      [issued;{issued with verb_json=(match issued.verb_json with
        | `Assoc fields -> `Assoc (List.rev fields) | other -> other)}];
    let payload = `Assoc ["ok",`Bool true;"data",`Assoc ["done",`Bool true]] in
    (match Browser_lane.deliver_result ~client_id:id ~id:issued.id ~payload with
     | Ok () -> () | Error detail -> fail detail);
    (match Eio.Promise.await_exn waiting with
     | Ok (Browser_lane.Answered result) -> check bool "owned waiter receives the host result" true (result=payload)
     | Ok (Browser_lane.Timed_out | Browser_lane.Lane_absent | Browser_lane.Refused _ | Browser_lane.Rejected_before_effect _)
     | Error _ -> fail "owned waiter was stranded after polling"))
    [Some "fixture-keeper",hovered;Some "fixture-keeper",dragged;None,Browser_lane.Tabs_list]

let test_malformed_poll_envelope_is_an_error () =
  List.iter (fun verb_json ->
    let issued : Browser_lane.issued = {id="malformed";verb_json} in
    let answer = Server_routes_http_routes_browser_lane.poll_answer_json issued in
    check bool "malformed envelope is not forwarded" true
      Yojson.Safe.Util.(answer |> member "verb" = `Null);
    check string "malformed envelope keeps its error" ("malformed verb envelope: " ^ Yojson.Safe.to_string verb_json)
      Yojson.Safe.Util.(answer |> member "error" |> to_string))
    [`Null;`Assoc [];`Assoc ["verb",`Int 1;"args",`Assoc []];`Assoc ["verb",`String "page.interact"]]

let () =
  run "browser lane routes"
    [ ( "discovery"
      , [ test_case "distinguishes transports with identical browser metadata" `Quick
            test_discovery_distinguishes_transports_of_the_same_browser ] )
    ; ( "ping"
      , [ test_case "answers only the lane token and registers no client" `Quick
            test_ping_answers_only_the_lane_token_and_registers_no_client ] )
    ; ( "poll"
      , [ test_case "native ingress has no builtin fallback" `Quick test_native_ingress_has_no_builtin_fallback
        ; test_case "unavailable causes have host-readable distinct codes" `Quick
            test_unavailable_causes_have_host_readable_distinct_codes
        ; test_case "owned pointer commands reach the host and settle their waiters" `Quick
            test_owned_pointer_poll_retains_command_and_settles_waiter
        ; test_case "malformed command envelopes remain errors" `Quick test_malformed_poll_envelope_is_an_error ] )
 ]
