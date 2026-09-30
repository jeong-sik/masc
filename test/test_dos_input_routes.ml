(* RFC play-link-for-the-shared-machine §2.5 through the real router: a
   person's press, type, step and pass reach the same DOS tools a Keeper
   calls, under the credential's name, and wait for their turn like one. *)

open Alcotest

let seats ~base_path =
  match Masc.Play_seat.participants ~base_path ~keepers:[] ~now:(Time_compat.now ()) with
  | Ok names -> names
  | Error error -> fail (Masc_domain.masc_error_to_string error)

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

let dispatch ~state ~target ~token ~body =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Server_routes_http_routes_dos.add_routes (Masc.Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf
        "POST %s HTTP/1.1\r\n\
         Host: 127.0.0.1:8935\r\n\
         Origin: http://127.0.0.1:8935\r\n\
         %sContent-Type: application/json\r\n\
         Content-Length: %d\r\n\
         \r\n\
         %s"
        target
        (match token with
         | Some token -> Printf.sprintf "Authorization: Bearer %s\r\n" token
         | None -> "")
        (String.length body) body
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

let message_of response =
  match body_of response with
  | `Assoc fields ->
    (match List.assoc_opt "message" fields with Some (`String m) -> m | _ -> "")
  | _ -> ""

let token_for base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (token, _) -> token
  | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)

(* Waits for a key, then exits: every press runs until it is ready again. *)
let hello_com = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let dos_ok what = function
  | Ok _ -> ()
  | Error e -> fail (what ^ ": " ^ Dos_lane.error_to_string e)

let controller () =
  match Dos_lane.screen () with
  | Ok { Dos_lane.controller; _ } -> controller
  | Error e -> fail ("screen: " ^ Dos_lane.error_to_string e)

let controller_opt () =
  match Dos_lane.screen () with
  | Ok { Dos_lane.controller; _ } -> controller
  | Error _ -> None

let contains ~sub s =
  let n = String.length sub and m = String.length s in
  let rec at i = i + n <= m && (String.sub s i n = sub || at (i + 1)) in
  at 0

let change_count () =
  match Dos_lane.live ~since:None with
  | Dos_lane.Changed (mark, _) -> mark.Dos_lane.count
  | Dos_lane.Unchanged _ | Dos_lane.Nothing_loaded -> fail "no DOS machine is loaded"

let newest_activity () =
  match Dos_lane.recent_activity () with
  | entry :: _ -> entry.Lane_activity.who, entry.Lane_activity.action
  | [] -> fail "no activity"

let starts_with ~prefix s = String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let test_a_person_plays_in_turn () =
  with_dir "dos-input-routes-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let operator = token_for base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let player = token_for base_path ~agent_name:"minsu" ~role:Masc_domain.Player in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let post ?token target body = dispatch ~state ~target ~token ~body in
      let dir = Filename.temp_dir "dos-input-machine-" "" in
      Fun.protect
        ~finally:(fun () ->
          (match Dos_lane.eject ~who:(Option.value (controller_opt ()) ~default:"operator") ~announce:ignore () with
           | Ok () | Error _ -> ());
          remove_tree dir)
        (fun () ->
          dos_ok "load"
            (Dos_lane.load ~who:"operator" ~ledger_dir:(Filename.concat dir "ledger")
               ~saves_dir:(Filename.concat dir "saves")
               ~checkpoint_dir:(Filename.concat dir "checkpoints") ~program_name:"game.com"
               ~program_bytes:hello_com ~files:[] ~announce:ignore);
          check (option string) "the loader holds the controller" (Some "operator") (controller ());
          check int "no bearer is refused" 401
            (status_of (post "/api/v1/dos/press" {|{"keys":["x"]}|}));
          let before = change_count () in
          let early = post ~token:player "/api/v1/dos/press" {|{"keys":["x"]}|} in
          check int "a press out of turn is refused" 400 (status_of early);
          check bool "and the refusal names who holds it" true (contains ~sub:"operator" (message_of early));
          check int "and the machine did not move" before (change_count ());
          List.iter
            (fun (target, body, what) ->
              check int what 400 (status_of (post ~token:operator target body));
              check int (what ^ " moves nothing") before (change_count ()))
            [ "/api/v1/dos/press", {|{"keys":"x"}|}, "keys as a string is a 400"
            ; "/api/v1/dos/press", {|{"keys":["x"],"steps":"100"}|}, "text steps is a 400"
            ; "/api/v1/dos/press", {|{"keys":["x"],"hold":1}|}, "an unknown field is a 400"
            ; "/api/v1/dos/type", {|{}|}, "type without text is a 400"
            ; "/api/v1/dos/step", {|{"until_ready":"yes"}|}, "a text until_ready is a 400"
            ; "/api/v1/dos/press", {|not json|}, "a body that is not JSON is a 400"
            ];
          let stray = post ~token:operator "/api/v1/dos/pass" {|{"to":"nobody"}|} in
          check int "a pass to a name not at the machine is a 400" 400 (status_of stray);
          check bool "and says so" true (contains ~sub:"not at the DOS machine" (message_of stray));
          check (option string) "and the operator keeps the controller" (Some "operator")
            (controller ());
          check int "the operator passes to the invite" 200
            (status_of (post ~token:operator "/api/v1/dos/pass" {|{"to":"minsu"}|}));
          check (option string) "the invite holds the controller" (Some "minsu") (controller ());
          check int "the invite presses on its turn" 200
            (status_of (post ~token:player "/api/v1/dos/press" {|{"keys":["x"]}|}));
          let who, action = newest_activity () in
          check string "the press is the invite's in the activity" "minsu" who;
          check bool "and names the press" true (starts_with ~prefix:"press" action);
          check bool "the machine moved" true (change_count () > before);
          check int "the invite steps" 200
            (status_of (post ~token:player "/api/v1/dos/step" {|{"steps":1000,"until_ready":false}|}));
          check int "the invite types" 200
            (status_of (post ~token:player "/api/v1/dos/type" {|{"text":"y"}|}));
          check int "a press by the operator out of turn is refused" 400
            (status_of (post ~token:operator "/api/v1/dos/press" {|{"keys":["x"]}|}));
          check int "the invite passes back" 200
            (status_of (post ~token:player "/api/v1/dos/pass" {|{"to":"operator"}|}));
          check (option string) "the operator holds it again" (Some "operator") (controller ()))))

let test_expired_credential_releases_controller_on_next_move role () =
  with_dir "dos-expired-credential-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let operator = token_for base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let holder_token =
      match Auth.create_token_expiring_in base_path ~agent_name:"minsu" ~role ~hours:1 with
      | Ok (token, _) -> token
      | Error error -> fail (Masc_domain.masc_error_to_string error)
    in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let post ~token target body = dispatch ~state ~target ~token:(Some token) ~body in
      let dir = Filename.temp_dir "dos-expired-machine-" "" in
      Fun.protect
        ~finally:(fun () ->
          (match Dos_lane.eject ~who:(Option.value (controller_opt ()) ~default:"operator") ~announce:ignore () with
           | Ok () | Error _ -> ());
          remove_tree dir)
        (fun () ->
          dos_ok "load"
            (Dos_lane.load ~who:"operator" ~ledger_dir:(Filename.concat dir "ledger")
               ~saves_dir:(Filename.concat dir "saves")
               ~checkpoint_dir:(Filename.concat dir "checkpoints") ~program_name:"game.com"
               ~program_bytes:hello_com ~files:[] ~announce:ignore);
          (match role with
           | Masc_domain.Admin | Masc_domain.Player ->
             check int "the operator passes to a valid credential holder" 200
               (status_of (post ~token:operator "/api/v1/dos/pass" {|{"to":"minsu"}|}))
           | Masc_domain.Worker ->
             check bool "a live Worker is not a handoff target" false
               (List.mem "minsu" (seats ~base_path));
             check int "the operator frees the controller" 200
               (status_of (post ~token:operator "/api/v1/dos/pass" {|{}|}));
             check (option string) "the controller is free" None (controller ());
             check int "a live Worker takes the free controller through a move" 200
               (status_of (post ~token:holder_token "/api/v1/dos/step" {|{"steps":1,"until_ready":false}|})));
          check int "the valid holder still owns the controller" 400
            (status_of (post ~token:operator "/api/v1/dos/pass" {|{"to":"operator"}|}));
          check (option string) "the valid holder keeps its turn" (Some "minsu") (controller ());
          let credential =
            match Auth.load_credential base_path "minsu" with
            | Some credential -> credential
            | None -> fail "the holder credential disappeared"
          in
          let expiry = "2030-01-01T00:00:00Z" in
          Auth.save_credential base_path { credential with expires_at = Some expiry };
          let expiry_second =
            match Time_codec.parse_rfc3339_opt expiry with
            | Some at -> at
            | None -> fail "the fixed expiry did not parse"
          in
          let holder_left ~now =
            match Auth.with_credential_transaction base_path (fun transaction ->
              Masc.Keeper_dos_controller.holder_left ~transaction
                ~config:(Masc.Mcp_server.workspace_config state) ~now "minsu") with
            | Ok departure -> departure
            | Error error -> fail (Masc_domain.masc_error_to_string error)
          in
          check bool "the holder is still eligible during its expiry second" true
            (Option.is_none (holder_left ~now:(expiry_second +. 0.5)));
          check bool "the holder has left once that second ends" true
            (match holder_left ~now:(expiry_second +. 1.) with
             | Some Masc.Tool_misc_dos_lane.Credential_expired -> true
             | Some (Masc.Tool_misc_dos_lane.Keeper_stopped | Masc.Tool_misc_dos_lane.No_credential)
             | None -> false);
          Auth.save_credential base_path
            { credential with expires_at = Some "2000-01-01T00:00:00Z" };
          check int "the router rejects the expired bearer" 401
            (status_of (post ~token:holder_token "/api/v1/dos/step" {|{"steps":1,"until_ready":false}|}));
          check bool "the expired credential is absent from handoff targets" false
            (List.mem "minsu" (seats ~base_path));
          check int "a stale handoff to the expired holder is refused" 400
            (status_of (post ~token:operator "/api/v1/dos/pass" {|{"to":"minsu"}|}));
          check (option string) "refusing the stale target leaves ownership unchanged"
            (Some "minsu") (controller ());
          check int "the operator moves after expiry without a manual revoke" 200
            (status_of (post ~token:operator "/api/v1/dos/pass" {|{"to":"operator"}|}));
          check (option string) "the operator now holds the controller" (Some "operator") (controller ());
          check bool "the expired turn was released in the lane ledger" true
            (List.exists
               (fun entry ->
                 String.equal entry.Lane_activity.who "minsu"
                 && String.equal entry.Lane_activity.action "released (idle)")
               (Dos_lane.recent_activity ())))))

let () =
  run "dos-input-routes"
    [ ("routes",
       [ test_case "a person presses, types, steps and passes in turn" `Quick test_a_person_plays_in_turn
       ; test_case "an expired invite releases its turn on the next move" `Quick
           (test_expired_credential_releases_controller_on_next_move Masc_domain.Player)
       ; test_case "an expired operator releases its turn on the next move" `Quick
           (test_expired_credential_releases_controller_on_next_move Masc_domain.Admin)
       ; test_case "an expired Worker releases a controller taken by a direct move" `Quick
           (test_expired_credential_releases_controller_on_next_move Masc_domain.Worker)
       ]) ]
