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
  (* The route reads its token file under the process's base path; this test
     executable owns that setting for its one scenario. *)
  Unix.putenv Env_config_core.base_path_env_key base;
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists token_file then Sys.remove token_file;
      List.iter
        (fun dir -> if Sys.file_exists dir then Sys.rmdir dir)
        [ lane; Filename.concat base ".masc"; base ])
    (fun () -> f ~lane ~token_file)

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
  with_workspace @@ fun ~lane ~token_file ->
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let router = Server_routes_http_routes_browser_lane.add_routes (Http.Router.create ()) in
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

(* A host reads why its poll was refused from the 400's body. The lane ended
   one of these clients, which a host that is still there replaces with a new
   ID; the other is held as another transport, which no new poll changes. *)
let test_a_refused_poll_names_its_reason () =
  with_workspace @@ fun ~lane ~token_file ->
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let router = Server_routes_http_routes_browser_lane.add_routes (Http.Router.create ()) in
  List.iter (fun dir -> Sys.mkdir dir 0o700) [ Filename.dirname lane; lane ];
  Out_channel.with_open_bin token_file (fun channel -> output_string channel token);
  let polled_as = "50000000-0000-4000-8000-000000000005" in
  let headers ~transport =
    [ "x-lane", "live"; "x-lane-token", token; "x-browser-client-id", polled_as
    ; "x-browser-name", "firefox"; "x-browser-version", "155.0"
    ; "x-browser-engine-version", "155.0"; "x-browser-transport", transport ]
  in
  let info =
    match
      Server_routes_http_routes_browser_lane.client_of_request
        (Httpun.Request.create ~headers:(Httpun.Headers.of_list (headers ~transport:"webdriver_bidi"))
           `POST "/browser-lane/poll")
    with
    | Ok info -> info
    | Error detail -> fail detail
  in
  (match Browser_lane.register info with
   | Ok _ -> ()
   | Error refusal -> fail (Browser_lane.registration_refusal_to_wire refusal));
  let refused_with code = `Assoc [ "ok", `Bool false; "error", `String code ] in
  let status, body = post router ~path:"/browser-lane/poll" ~headers:(headers ~transport:"web_extension") in
  check int "an ID held as another transport is refused" 400 status;
  check bool "with the code for it" true (body = refused_with "client_identity_changed");
  check bool "which a host reads as a refusal it would only meet again" true
    (Browser_lane.registration_refusal_of_wire "client_identity_changed"
     = Some Browser_lane.Client_identity_changed);
  (match Browser_lane.disconnect_client ~client_id:info.client_id with
   | Ok () -> ()
   | Error detail -> fail detail);
  let status, body = post router ~path:"/browser-lane/poll" ~headers:(headers ~transport:"webdriver_bidi") in
  check int "an ID the lane ended is refused" 400 status;
  check bool "with the code for it" true (body = refused_with "client_disconnected");
  check bool "which a host reads as a connection the lane ended" true
    (Browser_lane.registration_refusal_of_wire "client_disconnected" = Some Browser_lane.Client_retired);
  check bool "a code the lane does not send is no registration refusal" true
    (Browser_lane.registration_refusal_of_wire "unknown_lane" = None);
  List.iter (fun refusal ->
    check bool "each refusal reads back from its own code" true
      (Browser_lane.(registration_refusal_of_wire (registration_refusal_to_wire refusal)) = Some refusal))
    Browser_lane.[ Client_retired; Client_identity_changed ]

let () =
  run "browser lane routes"
    [ ( "discovery"
      , [ test_case "distinguishes transports with identical browser metadata" `Quick
            test_discovery_distinguishes_transports_of_the_same_browser ] )
    ; ( "ping"
      , [ test_case "answers only the lane token and registers no client" `Quick
            test_ping_answers_only_the_lane_token_and_registers_no_client ] )
    ; ( "poll"
      , [ test_case "a refused poll names its reason" `Quick test_a_refused_poll_names_its_reason ] ) ]
