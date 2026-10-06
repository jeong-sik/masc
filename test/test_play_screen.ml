(* RFC play-link-for-the-shared-machine §2.7 through the real router: an
   invite's bearer reads the shared DOS machine's frame as a PNG, and reading
   it never moves the machine. *)

open Alcotest
module Screen = Server_routes_http_routes_play_screen

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

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let dispatch_get ~state ~token =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Screen.add_routes (Masc.Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 8192 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf "GET %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\n%s\r\n"
        Screen.screen_path
        (match token with Some token -> Printf.sprintf "Authorization: Bearer %s\r\n" token | None -> "")
    in
    let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str in
    ignore (Httpun.Server_connection.read_eof conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string response_buf
                (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total + iov.len)
            0 iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)

let split_response response =
  let separator = "\r\n\r\n" in
  let rec find i =
    if i + 4 > String.length response then failf "no body in %S" response
    else if String.sub response i 4 = separator then i
    else find (i + 1)
  in
  let at = find 0 in
  String.sub response 0 at, String.sub response (at + 4) (String.length response - at - 4)

let status_of response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse response status: %S" response

let header name head =
  let prefix = String.lowercase_ascii name ^ ":" in
  String.split_on_char '\n' head
  |> List.find_map (fun line ->
    let line = String.trim line in
    if String.length line > String.length prefix
       && String.lowercase_ascii (String.sub line 0 (String.length prefix)) = prefix
    then Some (String.trim (String.sub line (String.length prefix) (String.length line - String.length prefix)))
    else None)

let token_for base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (token, _) -> token
  | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)

let hello_com = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let png_signature = "\x89PNG\r\n\x1a\n"

(* IHDR follows the signature: length(4) "IHDR"(4) width(4) height(4). *)
let ihdr_size png =
  let be32 at =
    (Char.code png.[at] lsl 24) lor (Char.code png.[at + 1] lsl 16)
    lor (Char.code png.[at + 2] lsl 8) lor Char.code png.[at + 3]
  in
  check string "the first chunk is IHDR" "IHDR" (String.sub png 12 4);
  be32 16, be32 20

let change_count () =
  match Dos_lane.live ~since:None with
  | Dos_lane.Changed (mark, _) -> mark.Dos_lane.count
  | Dos_lane.Unchanged _ | Dos_lane.Nothing_loaded -> fail "no DOS machine is loaded"

let test_the_screen_png () =
  with_dir "play-screen-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let player = token_for base_path ~agent_name:"minsu" ~role:Masc_domain.Player in
    let worker = token_for base_path ~agent_name:"codex" ~role:Masc_domain.Worker in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let get token = dispatch_get ~state ~token in
      (match Dos_lane.eject ~who:"operator" ~announce:ignore () with Ok () | Error _ -> ());
      check int "the screen needs a bearer" 401 (status_of (get None));
      check int "no program loaded is a conflict" 409 (status_of (get (Some player)));
      let dir = Filename.temp_dir "play-screen-dos-" "" in
      Fun.protect
        ~finally:(fun () ->
          Dos_lane.install_activity_observer None;
          (match Dos_lane.eject ~who:"operator" ~announce:ignore () with Ok () | Error _ -> ());
          remove_tree dir)
        (fun () ->
          Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
          (match
             Dos_lane.load ~who:"operator" ~ledger_dir:(Filename.concat dir "ledger")
               ~saves_dir:(Filename.concat dir "saves") ~checkpoint_dir:(Filename.concat dir "checkpoints")
               ~program_name:"game.com" ~program_bytes:hello_com ~files:[] ~announce:ignore
           with
           | Ok _ -> ()
           | Error e -> fail ("load: " ^ Dos_lane.error_to_string e));
          let frame_width, frame_height =
            match Dos_lane.capture () with
            | Ok (_, { Dos_lane.width; height; _ }) -> width, height
            | Error e -> fail ("capture: " ^ Dos_lane.error_to_string e)
          in
          let before = change_count () in
          let response = get (Some player) in
          check int "an invite reads the screen" 200 (status_of response);
          let head, png = split_response response in
          check (option string) "as a PNG" (Some "image/png") (header "content-type" head);
          check (option string) "not cached" (Some "no-store") (header "cache-control" head);
          check string "with the PNG signature" png_signature (String.sub png 0 (String.length png_signature));
          check (pair int int) "at the frame's size" (frame_width, frame_height) (ihdr_size png);
          check int "reading it did not move the machine" before (change_count ());
          check int "a worker reads it too" 200 (status_of (get (Some worker))))))

let () =
  run "play-screen"
    [ ("screen", [ test_case "an invite reads the frame as a PNG" `Quick test_the_screen_png ]) ]
