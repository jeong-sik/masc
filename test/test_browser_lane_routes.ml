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

let ping router ~headers =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
  in
  let header_lines =
    String.concat "" (List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n") headers)
  in
  let raw_request =
    "POST /browser-lane/ping HTTP/1.1\r\nHost: localhost\r\n" ^ header_lines
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

let host_headers presented =
  [ "x-lane", "live"; "x-lane-token", presented; "x-browser-client-id", client_id
  ; "x-browser-name", "firefox"; "x-browser-version", "155.0"
  ; "x-browser-engine-version", "155.0" ]

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

let () =
  run "browser lane routes"
    [ ( "ping"
      , [ test_case "answers only the lane token and registers no client" `Quick
            test_ping_answers_only_the_lane_token_and_registers_no_client ] ) ]
