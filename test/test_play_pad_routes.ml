(* RFC play-link-for-the-shared-machine §2.9 through the real router: the pad
   answers the loaded program's layout, and a button presses the machine keys
   it stands for, under the credential's name and in turn. *)

open Alcotest
module Routes = Server_routes_http_routes_play_pad

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

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let dispatch ~state ~meth ~token ~body =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Routes.add_routes (Masc.Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf
        "%s %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\n\
         Authorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
        meth Routes.pad_path token (String.length body) body
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

let status_of response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse response status: %S" response

let body_of response =
  let separator = "\r\n\r\n" in
  let rec find i =
    if i + 4 > String.length response then failf "no body in %S" response
    else if String.sub response i 4 = separator then i + 4
    else find (i + 1)
  in
  let start = find 0 in
  Yojson.Safe.from_string (String.sub response start (String.length response - start))

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let token_for base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (token, _) -> token
  | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)

(* Waits for a key, then exits: a press runs until it is ready again. *)
let hello_com = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let dos_ok what = function
  | Ok _ -> ()
  | Error e -> fail (what ^ ": " ^ Dos_lane.error_to_string e)

let eject_quietly () =
  List.iter
    (fun who -> match Dos_lane.eject ~who ~announce:ignore () with Ok () | Error _ -> ())
    [ "operator"; "minsu" ]

(* A machine whose saves live under [saves_name], as masc_dos_load names
   them after the inventory entry. *)
let with_machine ~saves_name f =
  let dir = Filename.temp_dir "play-pad-dos-" "" in
  Fun.protect
    ~finally:(fun () ->
      Dos_lane.install_activity_observer None;
      eject_quietly (); remove_tree dir)
    (fun () ->
      Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
      dos_ok "load"
        (Dos_lane.load ~who:"operator" ~ledger_dir:(Filename.concat dir "ledger")
           ~saves_dir:(Filename.concat (Filename.concat dir "saves") saves_name)
           ~checkpoint_dir:(Filename.concat dir "checkpoints") ~program_name:"KOEI.COM"
           ~program_bytes:hello_com ~files:[] ~announce:ignore);
      f ())

let change_count () =
  match Dos_lane.live ~since:None with
  | Dos_lane.Changed (mark, _) -> mark.Dos_lane.count
  | Dos_lane.Unchanged _ | Dos_lane.Nothing_loaded -> fail "no DOS machine is loaded"

let newest_activity () =
  match Dos_lane.recent_activity () with
  | entry :: _ -> entry.Lane_activity.who, entry.Lane_activity.action
  | [] -> fail "no activity"

let test_the_pad () =
  with_dir "play-pad-routes-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let operator = token_for base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let player = token_for base_path ~agent_name:"minsu" ~role:Masc_domain.Player in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let call ?(body = "") ~token meth = dispatch ~state ~meth ~token ~body in
      let press ?(saves_name = "samguk3") ~token button =
        call ~token "POST" ~body:(Printf.sprintf {|{"button":%S,"saves_name":%S}|} button saves_name)
      in
      eject_quietly ();
      check int "no program loaded is a conflict" 409 (status_of (call ~token:player "GET"));
      with_machine ~saves_name:"samguk3" (fun () ->
        let layout = call ~token:player "GET" in
        check int "a player reads the layout" 200 (status_of layout);
        let layout = body_of layout in
        check bool "for the program's saves name" true (member "saves_name" layout = Some (`String "samguk3"));
        check bool "from the builtin 삼국지3 layout" true (member "source" layout = Some (`String "builtin"));
        (match member "buttons" layout with
         | Some (`List buttons) -> check int "every button" 12 (List.length buttons)
         | _ -> fail "no buttons");
        let before = change_count () in
        let early = press ~token:player "BTN_SOUTH" in
        check int "a button out of turn is refused" 400 (status_of early);
        check int "and the machine did not move" before (change_count ());
        dos_ok "pass" (Dos_lane.pass ~who:"operator" ~to_:(Some "minsu") ~announce:ignore);
        List.iter
          (fun (body, what) -> check int what 400 (status_of (call ~token:player "POST" ~body)))
          [ {|{"button":"BTN_Z","saves_name":"samguk3"}|}, "an unknown button is a 400"
          ; {|{"button":"BTN_SOUTH","saves_name":"samguk3","keys":["x"]}|}, "an unknown field is a 400"
          ; {|{"button":"BTN_SOUTH"}|}, "no saves name is a 400"
          ; {|{"button":"BTN_SOUTH","saves_name":1}|}, "a saves name that is not a string is a 400"
          ; {|{}|}, "no button is a 400"
          ; {|not json|}, "not JSON is a 400"
          ];
        (* A pad read for another program: the server answers for the
           program loaded now instead of pressing that one's keys. *)
        let stale = press ~saves_name:"zzt" ~token:player "BTN_SOUTH" in
        check int "a pad read for another program is a conflict" 409 (status_of stale);
        check bool "naming the program loaded now" true
          (member "saves_name" (body_of stale) = Some (`String "samguk3"));
        (* The same check under the machine's lock, where a load between the
           screen read and the press would land. *)
        check bool "the lane refuses keys meant for another program" true
          (match Dos_lane.press_into ~saves_name:"zzt" ~who:"minsu" ~keys:[ "return" ] ~steps:100_000 with
           | Error (Dos_lane.Other_program { expected = "zzt"; loaded = "samguk3" }) -> true
           | Ok _ | Error _ -> false);
        check int "none of them moved the machine" before (change_count ());
        let pads = Masc.Play_pad.pads_dir ~base_path in
        mkdir_p pads;
        let override = Filename.concat pads "samguk3.toml" in
        let refuses_override what create remove =
          create ();
          Fun.protect ~finally:remove (fun () ->
            let before = change_count () in
            let activity = newest_activity () in
            List.iter (fun (meth, response) ->
              check int (what ^ " " ^ meth ^ " rejects the invalid workspace authority") 500
                (status_of response);
              check bool (what ^ " " ^ meth ^ " names the layout failure") true
                (member "code" (body_of response) = Some (`String "layout_invalid")))
              ["GET",call ~token:player "GET"; "POST",press ~token:player "BTN_SOUTH"];
            check int (what ^ " never presses builtin keys") before (change_count ());
            check bool (what ^ " preserves machine activity") true (newest_activity () = activity))
        in
        refuses_override "dangling layout link"
          (fun () -> Unix.symlink "missing-layout.toml" override) (fun () -> Unix.unlink override);
        refuses_override "unexamined looping layout link"
          (fun () -> Unix.symlink "samguk3.toml" override) (fun () -> Unix.unlink override);
        refuses_override "layout directory"
          (fun () -> Unix.mkdir override 0o700) (fun () -> Unix.rmdir override);
        refuses_override "layout FIFO without a writer"
          (fun () -> Unix.mkfifo override 0o600) (fun () -> Unix.unlink override);
        if Unix.geteuid () <> 0 then
          refuses_override "unsearchable layout directory"
            (fun () -> Unix.chmod pads 0) (fun () -> Unix.chmod pads 0o700);
        let target = Filename.concat base_path "layout-target.toml" in
        Out_channel.with_open_bin target (fun oc ->
          output_string oc "[BTN_SOUTH]\nkeys = [\"space\"]\nlabel = \"override\"\n");
        Unix.symlink target override;
        Fun.protect ~finally:(fun () -> Unix.unlink override) (fun () ->
          let layout = call ~token:player "GET" in
          check int "a regular symlink is a readable workspace override" 200 (status_of layout);
          let layout = body_of layout in
          check bool "symlink content keeps workspace authority" true
            (member "source" layout = Some (`String "workspace"));
          match member "buttons" layout with
          | Some (`List [button]) -> check bool "symlink override keeps its actual machine keys" true
              (member "keys" button = Some (`List [`String "space"]))
          | _ -> fail "symlink override did not supply its single button");
        check int "true absence restores the readable builtin" 200
          (status_of (call ~token:player "GET"));
        let pressed = press ~token:player "BTN_SOUTH" in
        check int "the holder presses a bound button" 200 (status_of pressed);
        let who, action = newest_activity () in
        check string "credited to the invite" "minsu" who;
        check string "as the machine key the button stands for" "press return" action;
        check bool "the machine moved" true (change_count () > before);
        (* The builtin 삼국지3 layout binds every button, so a workspace
           layout that binds one stands in for a layout that leaves one out. *)
        let pads = Masc.Play_pad.pads_dir ~base_path in
        mkdir_p pads;
        Out_channel.with_open_bin (Filename.concat pads "samguk3.toml") (fun oc ->
          output_string oc "[BTN_SOUTH]\nkeys = [\"return\"]\nlabel = \"결정\"\n");
        let moved = change_count () in
        check int "an unbound button is a 400" 400 (status_of (press ~token:player "BTN_TL"));
        check int "and the machine did not move" moved (change_count ()));
      with_machine ~saves_name:"zzt" (fun () ->
        let none = call ~token:operator "GET" in
        check int "a program with no layout is a 404" 404 (status_of none);
        check bool "naming the program" true (member "saves_name" (body_of none) = Some (`String "zzt")))))

let () =
  run "play-pad-routes"
    [ ("routes", [ test_case "layout, turn, unbound buttons and a press" `Quick test_the_pad ]) ]
