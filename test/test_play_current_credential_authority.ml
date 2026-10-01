(* Real Play seat/invite and DOS pass routes share current named authority.
   Old UUID and alias payloads stay intact as data across external replacement. *)
open Alcotest
module D = Masc_domain
module Invite = Masc.Play_invite

let () = Mirage_crypto_rng_unix.use_default ()

let auth_ok = function
  | Ok value -> value
  | Error error -> fail (D.masc_error_to_string error)

let dos_ok = function
  | Ok value -> value
  | Error error -> fail (Dos_lane.error_to_string error)

let read path = In_channel.with_open_bin path In_channel.input_all
let controller () = (dos_ok (Dos_lane.screen ())).Dos_lane.controller

let with_workspace f =
  let base_path = Filename.temp_dir "play-current-authority-" "" in
  Masc_test_deps.with_process_env "MASC_OAUTH_ENABLED" (Some "0") (fun () ->
    Eio_main.run @@ fun env ->
    Masc_test_deps.init_eio_clock env;
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 1893455900.;
    Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
    Eio.Switch.run @@ fun sw ->
    Eio.Switch.on_release sw (fun () ->
      (match Dos_lane.screen () with
       | Ok { controller; _ } ->
         (match Dos_lane.eject ~who:(Option.value controller ~default:"cleanup") ~announce:ignore () with
          | Ok () | Error _ -> ())
       | Error _ -> ());
      Time_compat.clear_clock ();
      Fs_compat.remove_tree base_path;
      Fs_compat.clear_fs ());
    Auth.save_auth_config base_path { D.default_auth_config with enabled = true; require_token = true };
    let operator, _ = auth_ok (Auth.create_token_without_expiry base_path ~agent_name:"operator" ~role:D.Admin) in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    let _screen = dos_ok (Dos_lane.load ~who:"operator"
      ~ledger_dir:(Filename.concat base_path "ledger") ~saves_dir:(Filename.concat base_path "saves")
      ~checkpoint_dir:(Filename.concat base_path "checkpoints") ~program_name:"spin.com"
      ~program_bytes:"\xeb\xfe" ~files:[] ~announce:ignore) in
    f base_path state operator)

let dispatch ~state ~token ~meth ~target ~body =
  let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority | Error `Malformed -> fail "invalid fixture authority" in
  Server_request_authority.with_current authority (fun () ->
    let router = Masc.Http_server_eio.Router.create ()
      |> Server_routes_http_routes_play.add_routes
      |> Server_routes_http_routes_play_page.add_routes
      |> Server_routes_http_routes_dos.add_routes in
    Server_auth.publish_server_state state;
    let response = Buffer.create 1024 in
    let connection = Httpun.Server_connection.create (fun reqd ->
      Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
    let request = Printf.sprintf
      "%s %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
      meth target token (String.length body) body in
    let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
    let _consumed = Httpun.Server_connection.read_eof connection bytes ~off:0 ~len:(Bigstringaf.length bytes) in
    let rec flush () = match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
        let count = List.fold_left (fun count (iov : Bigstringaf.t Httpun.IOVec.t) ->
          Buffer.add_string response (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
          count + iov.len) 0 iovecs in
        Httpun.Server_connection.report_write_result connection (`Ok count); flush ()
      | `Yield | `Close _ -> () in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response)

let status response = match String.split_on_char ' ' response with
  | _ :: code :: _ -> int_of_string code
  | _ -> fail "fixture response has no status"

let json response =
  let rec body at =
    if at + 4 > String.length response then fail "fixture response has no body"
    else if String.sub response at 4 = "\r\n\r\n" then at + 4
    else body (at + 1) in
  let at = body 0 in
  Yojson.Safe.from_string (String.sub response at (String.length response - at))

let member field = function
  | `Assoc fields -> List.assoc_opt field fields
  | _ -> None

let seed_guest base_path role =
  let token, initial = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"guest") in
  let credential = { initial with D.role; expires_at = Some "2030-01-01T00:00:00Z" } in
  Auth.save_credential base_path credential;
  let uuid = match credential.id with
    | Some id -> Auth.credential_file base_path (D.Credential_id.to_string id)
    | None -> fail "guest fixture requires a UUID" in
  let () = auth_ok (Auth.ensure_credential_alias base_path ~canonical_name:"guest" ~alias_name:"short-guest") in
  token, credential, uuid

let check_routes ~state ~operator ~names ~invites =
  let seat = dispatch ~state ~token:operator ~meth:"GET"
    ~target:Server_routes_http_routes_play_page.seat_path ~body:"" in
  check int "current seat route succeeds" 200 (status seat);
  check (option string) "seat names are current" (Some (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) names))))
    (Option.map Yojson.Safe.to_string (member "participants" (json seat)));
  let response = dispatch ~state ~token:operator ~meth:"GET"
    ~target:Server_routes_http_routes_play.invites_path ~body:"" in
  check int "current invite route succeeds" 200 (status response);
  let listed = match member "invites" (json response) with
    | Some (`List rows) -> List.map (fun row -> match member "name" row with
        | Some (`String name) -> name | _ -> fail "invite has no name") rows
    | _ -> fail "invite list missing" in
  check (list string) "invite names are current" invites listed

type transition = Removed | Worker

let test_surviving_data ~role transition = with_workspace @@ fun base_path state operator ->
  let guest_token, credential, uuid = seed_guest base_path role in
  let uuid_before = read uuid in
  let alias = Auth.credential_file base_path "short-guest" in
  let alias_before = read alias in
  check_routes ~state ~operator ~names:[ "guest"; "operator" ]
    ~invites:(match role with D.Player -> [ "guest" ] | D.Admin | D.Worker -> []);
  let pass token target = dispatch ~state ~token ~meth:"POST" ~target:"/api/v1/dos/pass"
      ~body:(Yojson.Safe.to_string (`Assoc [ "to", `String target ])) in
  check int "a healthy current guest receives the controller" 200 (status (pass operator "guest"));
  check (option string) "the guest holds its turn" (Some "guest") (controller ());
  check int "the current guest can pass back" 200 (status (pass guest_token "operator"));
  let named = Auth.credential_file base_path "guest" in
  let worker_token = "play-current-worker-fixture" in
  (match transition with
   | Removed -> Unix.unlink named
   | Worker ->
     let worker = { credential with D.id = None; role = D.Worker; token = Auth.sha256_hash worker_token } in
     Auth.save_private_text_file named (D.agent_credential_to_yojson worker |> Yojson.Safe.to_string));
  check_routes ~state ~operator ~names:[ "operator" ] ~invites:[];
  check int "a stale guest is not an eligible handoff target" 400 (status (pass operator "guest"));
  check (option string) "refused handoff preserves the operator turn" (Some "operator") (controller ());
  check int "current operator handoff remains usable" 200 (status (pass operator "operator"));
  (match transition with
   | Removed -> ()
   | Worker -> check bool "the current Worker still authenticates without becoming a seat" true
       (Result.is_ok (Auth.verify_token base_path ~agent_name:"guest" ~token:worker_token)));
  check string "old UUID bytes preserved" uuid_before (read uuid);
  check string "stored alias bytes preserved" alias_before (read alias);
  check bool "surviving alias remains readable as credential data" true
    (Auth.load_credential base_path "short-guest" = Some credential)

type unknown = Malformed | Dangling | Foreign

let test_unknown_current_binding unknown = with_workspace @@ fun base_path state operator ->
  let _, credential, uuid = seed_guest base_path D.Player in
  let uuid_before = read uuid in
  let named = Auth.credential_file base_path "guest" in
  let named_before = read named in
  (match unknown with
   | Malformed -> Auth.save_private_text_file named "{"
   | Dangling -> Unix.unlink named; Unix.symlink (named ^ ".absent") named
   | Foreign -> Auth.save_private_text_file named {|{"redirect_to":"operator.json"}|});
  check bool "unknown current authority is an Auth error" true (Result.is_error (Auth.list_current_credentials base_path));
  let seat = dispatch ~state ~token:operator ~meth:"GET"
      ~target:Server_routes_http_routes_play_page.seat_path ~body:"" in
  check int "unknown seats are not an empty successful list" 503 (status seat);
  let invites = dispatch ~state ~token:operator ~meth:"GET"
      ~target:Server_routes_http_routes_play.invites_path ~body:"" in
  check int "unknown invites are unavailable" 503 (status invites);
  check (option string) "invite refusal has a typed storage code" (Some "credentials_unreadable")
    (match member "code" (json invites) with Some (`String code) -> Some code | _ -> None);
  let passed = dispatch ~state ~token:operator ~meth:"POST" ~target:"/api/v1/dos/pass" ~body:{|{"to":"guest"}|} in
  check int "an unreadable seat cannot authorize a pass" 503 (status passed);
  check (option string) "unknown authority preserves the controller" (Some "operator") (controller ());
  check string "lookup preserves old UUID bytes" uuid_before (read uuid);
  (match unknown with
   | Malformed -> check string "malformed current file preserved" "{" (read named)
   | Dangling -> check string "dangling current binding preserved" (named ^ ".absent") (Unix.readlink named)
   | Foreign -> check string "foreign redirect preserved" {|{"redirect_to":"operator.json"}|} (read named));
  Unix.unlink named;
  Auth.save_private_text_file named named_before;
  check bool "current named credential is recovered" true (Auth.load_credential base_path "guest" = Some credential);
  check_routes ~state ~operator ~names:[ "guest"; "operator" ] ~invites:[ "guest" ]

let test_unresolved_data_does_not_hide_healthy_current_owners () = with_workspace @@ fun base_path state operator ->
  let _, _, _uuid = seed_guest base_path D.Player in
  let unresolved = Auth.credential_file base_path "unknown-data" in
  Auth.save_private_text_file unresolved "{";
  check_routes ~state ~operator ~names:[ "guest"; "operator" ] ~invites:[ "guest" ];
  check string "unresolved data with no established owner is preserved" "{" (read unresolved)

let test_stale_invalid_expiry_does_not_override_current_worker () =
  with_workspace @@ fun base_path state operator ->
  let _, old, uuid = seed_guest base_path D.Player in
  let current = { old with D.id = None; role = D.Worker;
    token = Auth.sha256_hash "current-worker-token" } in
  Auth.save_private_text_file (Auth.credential_file base_path "guest")
    (D.agent_credential_to_yojson current |> Yojson.Safe.to_string);
  Auth.save_private_text_file uuid
    (D.agent_credential_to_yojson { old with expires_at = Some "invalid-expiry" }
      |> Yojson.Safe.to_string);
  check_routes ~state ~operator ~names:["operator"] ~invites:[]

let () = run "Play current named authority" [ "routes", [
  test_case "invalid stale UUID cannot override current Worker" `Quick test_stale_invalid_expiry_does_not_override_current_worker;
  test_case "removed Player keeps data but loses seat and invite" `Quick (fun () -> test_surviving_data ~role:D.Player Removed);
  test_case "replaced Player uses current Worker authority" `Quick (fun () -> test_surviving_data ~role:D.Player Worker);
  test_case "removed Admin keeps data but loses seat" `Quick (fun () -> test_surviving_data ~role:D.Admin Removed);
  test_case "replaced Admin uses current Worker authority" `Quick (fun () -> test_surviving_data ~role:D.Admin Worker);
  test_case "malformed current binding refuses listing and pass" `Quick (fun () -> test_unknown_current_binding Malformed);
  test_case "dangling current binding refuses listing and pass" `Quick (fun () -> test_unknown_current_binding Dangling);
  test_case "foreign current binding refuses listing and pass" `Quick (fun () -> test_unknown_current_binding Foreign);
  test_case "unresolved ownerless data does not disable healthy seats" `Quick test_unresolved_data_does_not_hide_healthy_current_owners;
] ]
