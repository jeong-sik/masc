(* One real bearer, OAuth bootstrap and seat use the same whole-second expiry.
   The mock clock fixes the boundary; no sleeps or native wall-clock races. *)
open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

module Expiry = Types_auth.Credential_expiry
module Inventory = Auth_token_inventory
module Invite = Masc.Play_invite
module Seat = Masc.Play_seat

let expiry_second = 1893456000. (* 2030-01-01T00:00:00Z *)
let canonical = "2030-01-01T00:00:00Z"
let invalid_expiries = [ "zzz"; ""; "2030-02-30T00:00:00Z"; "2030-01-01T00:00:00" ]

let auth_ok = function
  | Ok value -> value
  | Error error -> fail (Masc_domain.masc_error_to_string error)

let oauth_ok = function
  | Ok value -> value
  | Error error -> fail (Auth_oauth.show_error error)

let with_workspace f =
  let base_path = Filename.temp_dir "credential-expiry-" "" in
  Masc_test_deps.with_process_env "MASC_OAUTH_ENABLED" (Some "1") (fun () ->
    Eio_main.run @@ fun env ->
    Masc_test_deps.init_eio_clock env;
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock (expiry_second -. 10.);
    Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
    Fun.protect
      ~finally:(fun () ->
        Time_compat.clear_clock ();
        Fs_compat.remove_tree base_path;
        Fs_compat.clear_fs ())
      (fun () ->
        Auth.save_auth_config base_path
          { Masc_domain.default_auth_config with enabled = true; require_token = true };
        f base_path clock))

let issue_oauth_pair base_path bootstrap_credential =
  let resource = "http://127.0.0.1:8935/mcp" in
  let redirect_uri = "http://127.0.0.1:43125/callback" in
  let client = oauth_ok (Auth_oauth.register_client ~base_path ~client_name:(Some "expiry-fixture")
      ~redirect_uris:[ redirect_uri ]) in
  let verifier = String.make 43 'v' in
  let request = oauth_ok (Auth_oauth.validate_authorization_request ~base_path
      ~expected_resource:resource ~response_type:(Some "code") ~client_id:(Some client.client_id)
      ~redirect_uri:(Some redirect_uri) ~resource:(Some resource) ~scope:(Some "mcp:admin")
      ~state:None ~code_challenge:(Some (Auth_oauth.pkce_s256 verifier))
      ~code_challenge_method:(Some "S256")) in
  let code = oauth_ok (Auth_oauth.issue_authorization_code ~base_path ~request ~bootstrap_credential) in
  let pair = oauth_ok (Auth_oauth.exchange_authorization_code ~base_path ~expected_resource:resource
      ~code ~client_id:client.client_id ~redirect_uri ~resource:(Some resource) ~code_verifier:verifier) in
  resource, client, pair

let test_representations_share_auth_and_prune_boundary () =
  List.iter (fun stamp ->
    with_workspace @@ fun base_path clock ->
    let token, initial = auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:"operator" ~role:Masc_domain.Admin) in
    let credential = { initial with expires_at = Some stamp } in
    Auth.save_credential base_path credential;
    let decoded = match Auth.load_credential base_path "operator" with
      | Some credential -> credential | None -> fail ("valid expiry did not decode: " ^ stamp) in
    check (option string) "wire input normalizes without rounding into the next second"
      (Some canonical) decoded.expires_at;
    let resource, _, pair = issue_oauth_pair base_path decoded in
    let oauth_access () = Auth_oauth.with_expected_resource resource (fun () ->
      Auth.find_credential_by_token base_path ~token:pair.access_token) in
    Eio_mock.Clock.set_time clock (expiry_second +. 0.5);
    check bool "static bearer remains live for the whole expiry second" true
      (Result.is_ok (Auth.find_static_credential_by_token base_path ~token));
    check bool "owner verification agrees during that second" true
      (Result.is_ok (Auth.verify_token base_path ~agent_name:"operator" ~token));
    check bool "OAuth live bootstrap agrees during that second" true (Result.is_ok (oauth_access ()));
    check (result bool string) "the same in-memory representation remains seated" (Ok false)
      (Invite.expired ~now:(Time_compat.now ()) credential |> Result.map_error
        (fun (Expiry.Invalid_timestamp stamp) -> stamp));
    check (list string) "the live credential remains a handoff target" [ "operator" ]
      (auth_ok (Seat.participants ~base_path ~keepers:[] ~now:(Time_compat.now ())));
    check int "prune excludes the still authenticating bearer" 0
      (List.length (Inventory.expired ~now:(Time_compat.now ()) [ credential ]));
    Eio_mock.Clock.set_time clock (expiry_second +. 1.);
    check bool "static bearer expires in the next whole second" true
      (Result.is_error (Auth.find_static_credential_by_token base_path ~token));
    check bool "owner verification expires with it" true
      (Result.is_error (Auth.verify_token base_path ~agent_name:"operator" ~token));
    check bool "OAuth refuses the expired bootstrap" true (Result.is_error (oauth_access ()));
    check (result bool string) "the expired in-memory representation leaves the seat" (Ok true)
      (Invite.expired ~now:(Time_compat.now ()) credential |> Result.map_error
        (fun (Expiry.Invalid_timestamp stamp) -> stamp));
    check (list string) "expired credentials are not handoff targets" []
      (auth_ok (Seat.participants ~base_path ~keepers:[] ~now:(Time_compat.now ())));
    check int "prune includes it only after authentication ends" 1
      (List.length (Inventory.expired ~now:(Time_compat.now ()) [ credential ])))
    [ canonical
    ; "2030-01-01T09:00:00+09:00"
    ; "2029-12-31T19:00:00-05:00"
    ; "2030-01-01T00:00:00.5Z"
    ; "2030-01-01T09:00:00.999999999999+09:00"
    ; "2029-12-31T19:00:00.999999999999-05:00"
    ]

let test_malformed_expiry_denies_a_known_bearer_and_bootstrap () =
  List.iter (fun stamp ->
    with_workspace @@ fun base_path _ ->
    let token, credential = auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:"operator" ~role:Masc_domain.Admin) in
    let resource, client, pair = issue_oauth_pair base_path credential in
    (* See the cache regression below: auth_ok checks the bearer; only warming is needed here. *)
    ignore (auth_ok (Auth.find_static_credential_by_token base_path ~token));
    let invalid = { credential with expires_at = Some stamp } in
    Auth.save_credential base_path invalid;
    check bool "present malformed expires_at is rejected by the credential decoder" true
      (Result.is_error (Masc_domain.agent_credential_of_yojson (Masc_domain.agent_credential_to_yojson invalid)));
    (match Expiry.parse invalid.expires_at with
     | Error (Expiry.Invalid_timestamp value) -> check string "typed error retains the stamp" stamp value
     | Ok _ -> fail "an invalid in-memory expiry cannot become non-expiring");
    check bool "a known cached static bearer cannot bypass malformed expiry" true
      (Result.is_error (Auth.find_static_credential_by_token base_path ~token));
    check bool "owner verification cannot bypass malformed expiry" true
      (Result.is_error (Auth.verify_token base_path ~agent_name:"operator" ~token));
    check bool "OAuth access rechecks the malformed live bootstrap" true
      (Result.is_error (Auth_oauth.with_expected_resource resource (fun () ->
        Auth.find_credential_by_token base_path ~token:pair.access_token)));
    check bool "the malformed bootstrap cannot refresh its OAuth grant" true
      (Result.is_error (Auth_oauth.rotate_refresh_token ~base_path ~expected_resource:resource
        ~refresh_token:pair.refresh_token ~client_id:client.client_id ~scope:None ~resource:(Some resource)));
    (match Invite.expired ~now:(Time_compat.now ()) invalid with
     | Error (Expiry.Invalid_timestamp value) -> check string "Play preserves the parse error" stamp value
     | Ok _ -> fail "an unknown expiry is not an expired or live credential");
    check (list string) "the invalid persisted credential is not seated" []
      (auth_ok (Seat.participants ~base_path ~keepers:[] ~now:(Time_compat.now ())));
    (match Inventory.classify ~now:(Time_compat.now ()) invalid with
     | Inventory.Invalid_expiry value -> check string "inventory reports invalid explicitly" stamp value
     | Inventory.Never | Inventory.Valid_until _ | Inventory.Expired_at _ ->
       fail "malformed expiry is neither a live credential nor a valid expired stamp");
    check int "automatic prune does not delete malformed evidence" 0
      (List.length (Inventory.expired ~now:(Time_compat.now ()) [ invalid ])))
    invalid_expiries

let test_malformed_expiry_keeps_the_controller () =
  List.iter (fun stamp ->
  with_workspace @@ fun base_path _ ->
  let _, credential = auth_ok (Auth.create_token_without_expiry base_path
      ~agent_name:"operator" ~role:Masc_domain.Admin) in
  let dos_ok = function
    | Ok value -> value
    | Error error -> fail (Dos_lane.error_to_string error) in
  Fun.protect
    (* See fixture cleanup: eject best effort after assertions, with no shared announcements. *)
    ~finally:(fun () ->
      Dos_lane.install_activity_observer None;
      ignore (Dos_lane.eject ~who:"operator" ~announce:ignore ()))
    (fun () ->
      Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
      (* Loading establishes the holder; its observation is unused. *)
      ignore (dos_ok (Dos_lane.load ~who:"operator"
        ~ledger_dir:(Filename.concat base_path "ledger") ~saves_dir:(Filename.concat base_path "saves")
        ~checkpoint_dir:(Filename.concat base_path "checkpoints") ~program_name:"spin.com"
        ~program_bytes:"\xeb\xfe" ~files:[] ~announce:ignore));
      Auth.save_credential base_path { credential with expires_at = Some stamp };
      auth_ok (Masc.Keeper_dos_controller.before_move
        ~config:(Masc.Workspace.default_config base_path) ~who:"visitor");
      check (option string) "invalid expiry is not proof that the holder left" (Some "operator")
        (dos_ok (Dos_lane.screen ())).controller;
      match Dos_lane.step ~who:"visitor" ~steps:1 ~until_ready:false with
      | Error (Dos_lane.Held_by _) -> ()
      | Error error -> fail (Dos_lane.error_to_string error)
      | Ok _ -> fail "an unknown expiry cannot free the controller for another caller"))
    invalid_expiries

let test_persisted_invalid_invite_reaches_diagnostic_projections () =
  List.iter (fun use_uuid ->
    with_workspace @@ fun base_path _ ->
    let token, credential = auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:"visitor" ~role:Masc_domain.Player) in
    let id = if use_uuid then Some (Masc_domain.Credential_id.generate ()) else None in
    Auth.save_credential base_path { credential with id; expires_at = Some "not-a-timestamp" };
    check bool "the malformed persisted bearer still fails authentication" true
      (Result.is_error (Auth.find_static_credential_by_token base_path ~token));
    let entries = Auth.list_credential_results base_path in
    (match entries with
     | [ Error (Auth.Invalid_credential_expiry { agent_name; role; timestamp }) ] ->
       check string "diagnostic retains the owner" "visitor" agent_name;
       check bool "diagnostic retains Player role" true (role = Masc_domain.Player);
       check string "diagnostic retains rejected expiry" "not-a-timestamp" timestamp;
       check string "inventory exposes persisted invalid expiry"
         (Printf.sprintf "%-32s %-6s INVALID expiry not-a-timestamp" "visitor" "player")
         (Inventory.error_row (Auth.Invalid_credential_expiry { agent_name; role; timestamp }))
     | _ -> fail "named and UUID-backed corruption must each produce exactly one diagnostic");
    (match Invite.list ~base_path ~now:(Time_compat.now ()) with
     | Error (Invite.Invalid_expiry (Expiry.Invalid_timestamp "not-a-timestamp")) -> ()
     | Error (Invite.Invalid_expiry (Expiry.Invalid_timestamp stamp)) ->
         fail ("unexpected invalid expiry: " ^ stamp)
     | Error (Invite.Credentials_unavailable error) ->
         fail (Masc_domain.masc_error_to_string error)
     | Ok _ -> fail "Play must not silently omit persisted malformed invites"))
    [ false; true ]

let test_invalid_exact_identity_refuses_prefix_bearer () =
  with_workspace @@ fun base_path _ ->
  let token, _owner = auth_ok (Auth.create_token_without_expiry base_path
      ~agent_name:"alpha" ~role:Masc_domain.Worker) in
  let exact_name = "keeper-alpha-agent" in
  let _, exact = auth_ok (Auth.create_token_without_expiry base_path
      ~agent_name:exact_name ~role:Masc_domain.Worker) in
  Auth.save_credential base_path { exact with expires_at = Some "invalid" };
  check bool "present invalid exact credential blocks prefix alias fallback" true
    (Result.is_error (Auth.verify_token base_path ~agent_name:exact_name ~token));
  let retired = Auth.with_credential_transaction base_path (fun transaction ->
    let present = auth_ok (Auth.credential_exists_in_transaction transaction exact_name) in
    check bool "explicit revoke still finds malformed credential" true present;
    Auth.delete_credential_in_transaction transaction exact_name) |> Result.join in
  let () = auth_ok retired in
  check bool "explicit revocation removes the malformed named file" false
    (Sys.file_exists (Auth.credential_file base_path exact_name))

let test_alias_revocation_preserves_canonical_owner () =
  List.iter (fun malformed -> with_workspace @@ fun base_path _ ->
    let canonical = "keeper-alpha-agent" in
    let token, credential = auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:canonical ~role:Masc_domain.Worker) in
    let id = Masc_domain.Credential_id.generate () in
    Auth.save_credential base_path { credential with id = Some id };
    Auth.save_private_text_file (Auth.raw_token_file base_path canonical) token;
    let () = auth_ok (Auth.ensure_credential_alias base_path ~canonical_name:canonical ~alias_name:"alpha") in
    if malformed then Auth.save_credential base_path
        { credential with id = Some id; expires_at = Some "invalid" };
    let paths = [Auth.credential_file base_path canonical; Auth.credential_file base_path "alpha";
                 Filename.concat (Filename.dirname (Auth.credential_file base_path canonical))
                   (Masc_domain.Credential_id.to_string id ^ ".json"); Auth.raw_token_file base_path canonical] in
    let bytes () = List.map (fun path -> In_channel.with_open_bin path In_channel.input_all) paths in
    let before = bytes () in
    let result = Auth.with_credential_transaction base_path (fun transaction ->
      Auth.delete_credential_in_transaction transaction "alpha") |> Result.join in
    check bool "alias cannot revoke canonical owner, even with malformed expiry" true (Result.is_error result);
    check bool "alias rejection preserves every canonical artifact" true (bytes () = before)) [false; true]

let test_malformed_direct_owner_revokes_verified_uuid () =
  List.iter (fun foreign -> with_workspace @@ fun base_path _ ->
    let token, credential = auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:"operator" ~role:Masc_domain.Worker) in
    let id = Masc_domain.Credential_id.generate () in
    let credential = { credential with id = Some id } in
    Auth.save_credential base_path credential;
    let named = Auth.credential_file base_path "operator" in
    let uuid = Filename.concat (Filename.dirname named) (Masc_domain.Credential_id.to_string id ^ ".json") in
    Auth.save_private_text_file named
      (Yojson.Safe.to_string (Masc_domain.agent_credential_to_yojson
        { credential with expires_at = Some "invalid" }));
    Auth.save_private_text_file (Auth.raw_token_file base_path "operator") token;
    if foreign then Auth.save_private_text_file uuid
      (Yojson.Safe.to_string (Masc_domain.agent_credential_to_yojson
        { credential with agent_name = "other" }));
    let paths = [named; uuid; Auth.raw_token_file base_path "operator"] in
    let snapshot () = List.map (fun path -> In_channel.with_open_bin path In_channel.input_all) paths in
    let before = snapshot () in
    let result = Auth.with_credential_transaction base_path (fun transaction ->
      Auth.delete_credential_in_transaction transaction "operator") |> Result.join in
    if foreign then (
      check bool "foreign UUID refuses revocation" true (Result.is_error result);
      check bool "refusal precedes every deletion" true (snapshot () = before))
    else (
      let () = auth_ok result in
      List.iter (fun path -> check bool "all canonical artifacts removed" false (Sys.file_exists path)) paths;
      check bool "old bearer cannot authenticate from remaining UUID index" true
        (Result.is_error (Auth.find_static_credential_by_token base_path ~token)))) [false; true]

let test_revoke_unlinks_dangling_named_path () =
  with_workspace @@ fun base_path _ ->
  let path = Auth.credential_file base_path "dangling" in
  Unix.symlink (Filename.concat base_path "missing-credential") path;
  let result = Auth.with_credential_transaction base_path (fun transaction ->
    check bool "dangling entry is admitted" true
      (auth_ok (Auth.credential_exists_in_transaction transaction "dangling"));
    Auth.delete_credential_in_transaction transaction "dangling") |> Result.join in
  let () = auth_ok result in
  let present = try let _ = Unix.lstat path in true
    with Unix.Unix_error (Unix.ENOENT, _, _) -> false in
  check bool "successful revoke actually unlinks the dangling entry" false present;
  check int "no diagnostic remains after revoke" 0 (List.length (Auth.list_credential_results base_path))

let test_dangling_credential_directory_is_unreadable () =
  with_workspace @@ fun base_path _ ->
  let dir = Filename.dirname (Auth.credential_file base_path "unused") in
  if Sys.file_exists dir then Unix.rmdir dir;
  Unix.symlink (Filename.concat base_path "absent-target") dir;
  (match Auth.list_credential_results base_path with
   | [ Error (Auth.Unreadable_credential _) ] -> ()
   | _ -> fail "a dangling agents directory is a storage failure, not an empty store");
  (match Invite.list ~base_path ~now:(Time_compat.now ()) with
   | Error (Invite.Credentials_unavailable _) -> ()
   | _ -> fail "Play must preserve credential directory failures")

let test_nonregular_inventory_entries_are_unreadable () =
  List.iter (fun kind ->
    with_workspace @@ fun base_path _ ->
    let _, regular = auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:"regular" ~role:Masc_domain.Player) in
    let named = Auth.credential_file base_path "blocked" in
    let fifo, diagnostic_path = match kind with
      | `Direct -> named, named
      | `Symlink ->
          let fifo = Filename.concat base_path "credential-fifo" in
          Unix.symlink fifo named;
          fifo, named
      | `Redirect ->
          let id = Masc_domain.Credential_id.generate () in
          let target = Masc_domain.Credential_id.to_string id ^ ".json" in
          Auth.save_private_text_file named
            (Yojson.Safe.to_string (`Assoc ["redirect_to", `String target]));
          let fifo = Filename.concat (Filename.dirname named) target in
          fifo, fifo
    in
    Unix.mkfifo fifo 0o600;
    (* No writer opens the FIFO: inventory must reject its descriptor before
       any read, including through a symlink or credential redirect. *)
    Fun.protect ~finally:(fun () -> Unix.unlink fifo) (fun () ->
      let entries = Auth.list_credential_results base_path in
      check (list string) "ordinary credentials remain visible" [regular.agent_name]
        (List.filter_map (function Ok credential -> Some credential.Masc_domain.agent_name
          | Error _ -> None) entries);
      (match List.filter_map (function Error error -> Some error | Ok _ -> None) entries with
       | [Auth.Unreadable_credential {path;_}] ->
           check string "inventory retains the failed path" diagnostic_path path
       | _ -> fail "a nonregular entry must be one unreadable diagnostic");
      (match Invite.list ~base_path ~now:(Time_compat.now ()) with
       | Error (Invite.Credentials_unavailable _) -> ()
       | _ -> fail "Play must refuse an unreadable credential store")))
    [`Direct; `Symlink; `Redirect]

let () =
  run "credential expiry feature"
    [ "bearer, OAuth, seats and inventory",
      [ test_case "nonregular inventory entries do not wait for FIFO writers" `Quick
          test_nonregular_inventory_entries_are_unreadable
      ; test_case "malformed direct owner revokes only its verified UUID" `Quick test_malformed_direct_owner_revokes_verified_uuid
      ; test_case "redirect aliases cannot revoke canonical owners" `Quick test_alias_revocation_preserves_canonical_owner
      ; test_case "revoke actually unlinks dangling named paths" `Quick test_revoke_unlinks_dangling_named_path
      ; test_case "malformed exact credential refuses prefix bearer and can be revoked" `Quick
          test_invalid_exact_identity_refuses_prefix_bearer
      ; test_case "dangling credential directory is unavailable" `Quick
          test_dangling_credential_directory_is_unreadable
      ; test_case "persisted malformed invites reach listings and inventory" `Quick
          test_persisted_invalid_invite_reaches_diagnostic_projections
      ; test_case "offsets and fractions share the whole-second boundary" `Quick
          test_representations_share_auth_and_prune_boundary
      ; test_case "malformed expiry denies a known bearer and live OAuth bootstrap" `Quick
          test_malformed_expiry_denies_a_known_bearer_and_bootstrap
      ; test_case "malformed expiry preserves the controller" `Quick
          test_malformed_expiry_keeps_the_controller ] ]
