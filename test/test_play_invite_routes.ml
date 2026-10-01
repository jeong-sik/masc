(* RFC play-link-for-the-shared-machine §2.4 and §5 through the real router:
   who may issue, what the answer carries, and that revoking a name that holds
   the DOS controller frees it. *)

open Alcotest
module Routes = Server_routes_http_routes_play

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

let dispatch ~state ~meth ~target ~token ~body =
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
        "%s %s HTTP/1.1\r\n\
         Host: 127.0.0.1:8935\r\n\
         Origin: http://127.0.0.1:8935\r\n\
         Authorization: Bearer %s\r\n\
         Content-Type: application/json\r\n\
         Content-Length: %d\r\n\
         \r\n\
         %s"
        meth target token (String.length body) body
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

let string_member name json =
  match member name json with Some (`String s) -> s | _ -> failf "no string %s in %s" name (Yojson.Safe.to_string json)

let bool_member name json =
  match member name json with Some (`Bool b) -> b | _ -> failf "no bool %s in %s" name (Yojson.Safe.to_string json)

let token_for base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (token, _) -> token
  | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)

let hello_com = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let dos_ok what = function
  | Ok _ -> ()
  | Error e -> fail (what ^ ": " ^ Dos_lane.error_to_string e)

let controller () =
  match Dos_lane.screen () with
  | Ok { Dos_lane.controller; _ } -> controller
  | Error e -> fail ("screen: " ^ Dos_lane.error_to_string e)

let test_invite_routes () =
  with_dir "play-invite-routes-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let operator = token_for base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let worker = token_for base_path ~agent_name:"codex" ~role:Masc_domain.Worker in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" (Some "http://127.0.0.1:8935") (fun () ->
      Eio_main.run (fun env ->
        Masc_test_deps.init_eio_clock env;
        let call ?(body = "") ~token meth target = dispatch ~state ~meth ~target ~token ~body in
        let invites = Routes.invites_path in
        let issue_body = {|{"name":"minsu","hours":2}|} in
        check int "a worker cannot issue" 403 (status_of (call ~token:worker "POST" invites ~body:issue_body));
        let issued = call ~token:operator "POST" invites ~body:issue_body in
        check int "the operator issues" 201 (status_of issued);
        let issued = body_of issued in
        check string "the answer names the invite" "minsu" (string_member "name" issued);
        let link = string_member "link" issued in
        let prefix = "http://127.0.0.1:8935/play#" in
        check string "the link opens the play page" prefix (String.sub link 0 (String.length prefix));
        let player = String.sub link (String.length prefix) (String.length link - String.length prefix) in
        check int "a player cannot issue" 403 (status_of (call ~token:player "POST" invites ~body:issue_body));
        check int "a player cannot list" 403 (status_of (call ~token:player "GET" invites));
        let again = call ~token:operator "POST" invites ~body:issue_body in
        check int "the same name again is a conflict" 409 (status_of again);
        check string "because a credential has it" "credential" (string_member "taken_by" (body_of again));
        (* Server_refusal: [code] is what a client branches on, [error] the
           sentence a person reads. *)
        check string "named by its code" "name_taken" (string_member "code" (body_of again));
        check string "and said in a sentence" "another participant already has this name"
          (string_member "error" (body_of again));
        List.iter
          (fun (body, what) ->
            check int what 400 (status_of (call ~token:operator "POST" invites ~body)))
          [ {|{"name":"Minsu","hours":2}|}, "an uppercase name is a 400"
          ; {|{"name":"min-su","hours":2}|}, "a hyphenated name is a 400"
          ; {|{"name":"minji"}|}, "no hours is a 400: an invite always expires"
          ; {|{"name":"minji","hours":"2"}|}, "text hours is a 400"
          ; {|{"name":"minji","hours":0}|}, "zero hours is a 400"
          ; {|not json|}, "a body that is not JSON is a 400"
          ];
        let dir = Filename.temp_dir "play-invite-dos-" "" in
        Fun.protect
          ~finally:(fun () ->
            (match Dos_lane.eject ~who:"operator" ~announce:ignore () with
             | Ok () | Error _ -> ());
            remove_tree dir)
          (fun () ->
            dos_ok "load"
              (Dos_lane.load ~who:"operator" ~ledger_dir:(Filename.concat dir "ledger")
                 ~saves_dir:(Filename.concat dir "saves")
                 ~checkpoint_dir:(Filename.concat dir "checkpoints") ~program_name:"game.com"
                 ~program_bytes:hello_com ~files:[] ~announce:ignore);
            dos_ok "pass" (Dos_lane.pass ~who:"operator" ~to_:(Some "minsu") ~announce:ignore);
            check (option string) "the invite holds the controller" (Some "minsu") (controller ());
            (match member "invites" (body_of (call ~token:operator "GET" invites)) with
             | Some (`List [ entry ]) ->
               check string "listed by name" "minsu" (string_member "name" entry);
               check bool "not expired" false (bool_member "expired" entry);
               check bool "holding the controller" true (bool_member "holds_controller" entry)
             | _ -> fail "the list is not the one invite");
            let revoked = call ~token:operator "DELETE" (invites ^ "/minsu") in
            check int "the operator revokes" 200 (status_of revoked);
            check bool "and the controller it held is freed" true
              (bool_member "released_controller" (body_of revoked));
            check (option string) "nobody holds the controller" None (controller ()));
        check bool "the revoked bearer stops resolving" true
          (Result.is_error (Auth.find_credential_by_token base_path ~token:player));
        let gone = call ~token:operator "DELETE" (invites ^ "/minsu") in
        check int "revoking it again finds nothing" 404 (status_of gone);
        check string "the code the TUI reads as already gone" "no_such_invite"
          (string_member "code" (body_of gone));
        (* A request the invitee sent before the delete can take the freed
           controller after it. Revoking again frees it. *)
        let dir = Filename.temp_dir "play-invite-retake-" "" in
        Fun.protect
          ~finally:(fun () ->
            (match Dos_lane.eject ~who:"operator" ~announce:ignore () with
             | Ok () | Error _ -> ());
            remove_tree dir)
          (fun () ->
            dos_ok "load"
              (Dos_lane.load ~who:"operator" ~ledger_dir:(Filename.concat dir "ledger")
                 ~saves_dir:(Filename.concat dir "saves")
                 ~checkpoint_dir:(Filename.concat dir "checkpoints") ~program_name:"game.com"
                 ~program_bytes:hello_com ~files:[] ~announce:ignore);
            dos_ok "the late request" (Dos_lane.pass ~who:"operator" ~to_:(Some "minsu") ~announce:ignore);
            let freed = call ~token:operator "DELETE" (invites ^ "/minsu") in
            check int "revoking a gone invite that holds the controller frees it" 200 (status_of freed);
            check bool "it says nothing was revoked" false (bool_member "revoked" (body_of freed));
            check bool "and that the controller was freed" true
              (bool_member "released_controller" (body_of freed));
            check (option string) "nobody holds the controller" None (controller ()));
        let not_invite = call ~token:operator "DELETE" (invites ^ "/codex") in
        check int "a worker's credential is not an invite" 409 (status_of not_invite);
        check bool "and the worker keeps it" true (Option.is_some (Auth.load_credential base_path "codex")))))

let test_invalid_persisted_invite_is_unavailable () =
  with_dir "play-invalid-expiry-route-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let operator = token_for base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let player = token_for base_path ~agent_name:"visitor" ~role:Masc_domain.Player in
    let credential = match Auth.load_credential base_path "visitor" with
      | Some value -> value | None -> fail "fixture Player is missing" in
    Auth.save_credential base_path { credential with expires_at = Some "invalid-expiry" };
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let result = dispatch ~state ~meth:"GET" ~target:Routes.invites_path ~token:operator ~body:"" in
      check int "persisted malformed invite returns 503" 503 (status_of result);
      check string "route preserves the typed expiry failure" "invalid_credential_expiry"
        (string_member "code" (body_of result));
      check bool "invalid bearer remains denied" true
        (Result.is_error (Auth.find_static_credential_by_token base_path ~token:player))))

let () =
  run "play-invite-routes"
    [ ("routes", [ test_case "persisted malformed invite returns 503" `Quick test_invalid_persisted_invite_is_unavailable
      ; test_case "issue, list and revoke through the router" `Quick test_invite_routes ]) ]
