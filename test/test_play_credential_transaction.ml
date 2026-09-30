(* The real credential publisher and DOS controller recovery contend on one
   transaction. No sleeps: the durable lock's admission hook fixes the order. *)
open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let auth_ok = function
  | Ok value -> value
  | Error error -> fail (Masc_domain.masc_error_to_string error)

let dos_ok = function
  | Ok value -> value
  | Error error -> fail (Dos_lane.error_to_string error)

let controller () = (dos_ok (Dos_lane.screen ())).Dos_lane.controller

let lock_path base_path =
  Filename.concat (Unix.realpath (Auth.auth_dir base_path)) ".credentials.lock"

let with_machine f =
  let base_path = Filename.temp_dir "play-credential-transaction-" "" in
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect
    ~finally:(fun () ->
      (match Dos_lane.screen () with
       | Ok { controller = Some who; _ } ->
         ignore (Dos_lane.eject ~who ~announce:ignore ())
       | Ok { controller = None; _ } ->
         ignore (Dos_lane.eject ~who:"cleanup" ~announce:ignore ())
       | Error _ -> ());
      Fs_compat.remove_tree base_path;
      Fs_compat.clear_fs ())
    (fun () ->
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      let token, credential = auth_ok
          (Auth.create_token base_path ~agent_name:"player" ~role:Masc_domain.Player) in
      let expired = { credential with expires_at = Some "2000-01-01T00:00:00Z" } in
      Auth.save_credential base_path expired;
      ignore (dos_ok (Dos_lane.load ~who:"player"
        ~ledger_dir:(Filename.concat base_path "ledger")
        ~saves_dir:(Filename.concat base_path "saves")
        ~checkpoint_dir:(Filename.concat base_path "checkpoints")
        ~program_name:"spin.com" ~program_bytes:"\xeb\xfe" ~files:[] ~announce:ignore));
      f (Workspace.default_config base_path) token expired)

let recover config =
  Keeper_dos_controller.before_call ~config ~who:"operator" ~name:"masc_dos_step"
    ~args:(`Assoc [ "steps", `Int 1; "until_ready", `Bool false ])

let recovered = function
  | Ok () -> ()
  | Error (Keeper_dos_controller.Refused detail | Keeper_dos_controller.Seats_unknown detail) -> fail detail

let renew config = auth_ok
    (Auth.create_token_expiring_in config.Workspace.base_path
       ~agent_name:"player" ~role:Masc_domain.Player ~hours:1)

let await_waiter ~base_path completed =
  let rec wait () =
    if File_lock_eio.For_testing.holders_and_waiters ~lock_path:(lock_path base_path) >= 2
    then ()
    else match Eio.Promise.peek completed with
      | Some _ -> fail "the competing operation completed outside the credential transaction"
      | None -> Eio.Fiber.yield (); wait () in
  wait ()

let interleave config first second =
  let admitted, signal_admitted = Eio.Promise.create () in
  let continue, signal_continue = Eio.Promise.create () in
  let first_done, signal_first_done = Eio.Promise.create () in
  let second_done, signal_second_done = Eio.Promise.create () in
  let armed = Atomic.make true in
  let previous = Atomic.get File_lock_eio.on_lock_attempt_fn in
  Atomic.set File_lock_eio.on_lock_attempt_fn
    (fun ~caller ~retries ~elapsed_s ~outcome ->
      previous ~caller ~retries ~elapsed_s ~outcome;
      if String.equal caller "File_lock_eio.durable" && Atomic.compare_and_set armed true false then (
        Eio.Promise.resolve signal_admitted ();
        Eio.Promise.await continue));
  Fun.protect ~finally:(fun () -> Atomic.set File_lock_eio.on_lock_attempt_fn previous)
    (fun () -> Eio.Switch.run @@ fun sw ->
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_first_done (first ()));
      let rec await_first () =
        match Eio.Promise.peek admitted, Eio.Promise.peek first_done with
        | Some (), _ -> ()
        | None, Some _ -> fail "the first operation bypassed the credential transaction"
        | None, None -> Eio.Fiber.yield (); await_first () in
      await_first ();
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_second_done (second ()));
      await_waiter ~base_path:config.Workspace.base_path second_done;
      Eio.Promise.resolve signal_continue ();
      Eio.Promise.await first_done, Eio.Promise.await second_done)

let test_completed_renewal_preserves_the_controller () =
  with_machine @@ fun config old_token expired ->
  (* Populate the token index before the guarded publisher invalidates it. *)
  check bool "the old bearer is expired" true
    (Result.is_error (Auth.find_static_credential_by_token config.base_path ~token:old_token));
  let (new_token, _), recovery = interleave config
      (fun () -> renew config) (fun () -> recover config) in
  recovered recovery;
  check string "renewal publishes a usable bearer" "player"
    (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:new_token)).agent_name;
  check bool "the cached old bearer is not revived" true
    (Result.is_error (Auth.find_static_credential_by_token config.base_path ~token:old_token));
  check (option string) "a completed renewal keeps the same-name holder" (Some "player") (controller ());
  (match Dos_lane.step ~who:"operator" ~steps:1 ~until_ready:false with
   | Error (Dos_lane.Held_by _) -> ()
   | Error error -> fail (Dos_lane.error_to_string error)
   | Ok _ -> fail "another caller moved after the holder renewed");
  Auth.save_credential config.base_path expired;
  recovered (recover config);
  ignore (dos_ok (Dos_lane.step ~who:"operator" ~steps:1 ~until_ready:false));
  check (option string) "an actually expired holder is still recoverable" (Some "operator") (controller ())

let test_recovery_before_renewal_has_one_order () =
  with_machine @@ fun config _ _ ->
  let recovery, (new_token, _) = interleave config
      (fun () -> recover config) (fun () -> renew config) in
  recovered recovery;
  check (option string) "the earlier expiry decision released the old turn" None (controller ());
  ignore (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:new_token));
  ignore (dos_ok (Dos_lane.step ~who:"player" ~steps:1 ~until_ready:false));
  check (option string) "the renewed holder can take the free controller" (Some "player") (controller ())

let test_cold_index_cannot_restore_credentials_after_renewal () =
  with_machine @@ fun config old_token _ ->
  let old_lookup, (new_token, _) = interleave config
      (fun () -> Auth.find_static_credential_by_token config.base_path ~token:old_token)
      (fun () -> renew config) in
  check bool "the earlier index saw the expired bearer" true (Result.is_error old_lookup);
  check string "renewal invalidation wins over the earlier cold publication" "player"
    (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:new_token)).agent_name

let test_cancelled_delete_leaves_credential_and_releases_admission () =
  with_machine @@ fun config _ _ ->
  let cancelled = auth_ok (Auth.with_credential_transaction config.base_path (fun _transaction ->
    Eio.Fiber.first
      (fun () -> Auth.delete_credential config.base_path "player"; false)
      (fun () ->
        let never_completed, _ = Eio.Promise.create () in
        await_waiter ~base_path:config.base_path never_completed;
        true))) in
  check bool "the contended deletion was cancelled" true cancelled;
  check bool "cancellation before admission deletes nothing" true
    (Option.is_some (Auth.load_credential config.base_path "player"));
  ignore (renew config);
  recovered (recover config);
  check (option string) "subsequent publication and recovery can acquire the lock"
    (Some "player") (controller ());
  Auth.delete_credential config.base_path "player";
  recovered (recover config);
  check (option string) "a completed deletion still frees an absent holder" None (controller ())

let revoke config =
  Server_routes_http_routes_play.For_testing.revoke_response
    ~config ~by:"operator" ~raw_name:"player"

let check_status expected (actual, body) =
  if actual <> expected then failf "unexpected HTTP result: %s" (Yojson.Safe.to_string body)

let renew_as_admin config = auth_ok
    (Auth.create_token_expiring_in config.Workspace.base_path
       ~agent_name:"player" ~role:Masc_domain.Admin ~hours:1)

let issue config =
  let name = match Play_invite.Name.of_string "player" with
    | Ok name -> name | Error detail -> fail detail in
  Play_invite.issue ~base_path:config.Workspace.base_path
    ~public_base_url:(Some "https://play.example.test") ~keeper_names:(Ok []) ~name ~hours:1

let test_renewal_before_issue_preserves_current_credential () =
  with_machine @@ fun config old_token _ ->
  Auth.delete_credential config.base_path "player";
  ignore (Auth.find_static_credential_by_token config.base_path ~token:old_token);
  let (admin_token, admin), invitation = interleave config
      (fun () -> renew_as_admin config) (fun () -> issue config) in
  (match invitation with
   | Error (Play_invite.Name_taken Play_invite.Credential) -> ()
   | Ok _ | Error _ -> fail "a queued invitation must refuse the newly published Admin name");
  let current = auth_ok (Auth.find_static_credential_by_token config.base_path ~token:admin_token) in
  check string "the Admin bearer, not a replacement Player, owns the name"
    "admin" (Masc_domain.agent_role_to_string current.role);
  check string "the exact published credential survives" admin.token current.token;
  check (option string) "issue refusal does not release the turn" (Some "player") (controller ())

let test_competing_issues_publish_only_one_invite () =
  with_machine @@ fun config _ _ ->
  Auth.delete_credential config.base_path "player";
  let first, second = interleave config (fun () -> issue config) (fun () -> issue config) in
  let issued = match first with
    | Ok issued -> issued | Error _ -> fail "the admitted invitation must be published" in
  (match second with
   | Error (Play_invite.Name_taken Play_invite.Credential) -> ()
   | Ok _ | Error _ -> fail "the second invitation must refuse the occupied name");
  let token = match String.index_opt issued.link '#' with
    | Some offset -> String.sub issued.link (offset + 1) (String.length issued.link - offset - 1)
    | None -> fail "the invitation link must contain its bearer" in
  check string "the first invite's bearer still authenticates" "player"
    (auth_ok (Auth.find_static_credential_by_token config.base_path ~token)).agent_name

let unreadable_name_fixtures =
  [ "invalid JSON", (fun path -> Out_channel.with_open_text path (fun channel -> output_string channel "{"))
  ; "missing redirect target", (fun path -> Out_channel.with_open_text path
      (fun channel -> output_string channel {|{"redirect_to":"absent.json"}|}))
  ; "dangling symlink", (fun path -> Unix.unlink path; Unix.symlink (path ^ ".absent") path)
  ; "directory", (fun path -> Unix.unlink path; Unix.mkdir path 0o700)
  ]

let test_unreadable_revoke_preserves_effects () =
  List.iter (fun (label, corrupt) ->
    with_machine @@ fun config _ _ ->
    let path = Auth.credential_file config.base_path "player" in
    corrupt path;
    let name = match Play_invite.Name.of_string "player" with
      | Ok name -> name | Error detail -> fail detail in
    let callback_ran = ref false in
    (match Play_invite.revoke ~base_path:config.base_path ~name
        ~after_revoke:(fun _ -> callback_ran := true) with
     | Error Play_invite.Credential_unreadable -> ()
     | Ok () | Error _ -> fail (label ^ ": an unreadable name must be refused"));
    check bool (label ^ ": no callback") false !callback_ran;
    let status, body = revoke config in
    check_status `Service_unavailable (status, body);
    check string (label ^ ": explicit route error") "credential_unreadable"
      Yojson.Safe.Util.(member "code" body |> to_string);
    check (option string) (label ^ ": the turn survives") (Some "player") (controller ());
    ignore (Unix.lstat path)) unreadable_name_fixtures

let test_unreadable_recovery_preserves_controller () =
  List.iter (fun (label, corrupt) ->
    with_machine @@ fun config _ _ ->
    let path = Auth.credential_file config.base_path "player" in
    corrupt path;
    recovered (recover config);
    check (option string) (label ^ ": recovery keeps the ambiguous holder")
      (Some "player") (controller ());
    (match Dos_lane.step ~who:"operator" ~steps:1 ~until_ready:false with
     | Error (Dos_lane.Held_by _) -> ()
     | Error error -> fail (Dos_lane.error_to_string error)
     | Ok _ -> fail (label ^ ": another participant moved after ambiguous recovery"));
    ignore (Unix.lstat path)) unreadable_name_fixtures

let test_mismatched_revoke_preserves_effects () =
  List.iter (fun role ->
    with_machine @@ fun config _ credential ->
    let path = Auth.credential_file config.base_path "player" in
    let mismatched = { credential with agent_name = "other"; role } in
    let json = Masc_domain.agent_credential_to_yojson mismatched |> Yojson.Safe.to_string in
    Out_channel.with_open_text path (fun channel -> output_string channel json);
    let name = match Play_invite.Name.of_string "player" with
      | Ok name -> name | Error detail -> fail detail in
    let callback_ran = ref false in
    (match Play_invite.revoke ~base_path:config.base_path ~name
        ~after_revoke:(fun _ -> callback_ran := true) with
     | Error (Play_invite.Credential_identity_mismatch "other") -> ()
     | Ok () | Error _ -> fail "a name resolving to another owner must be refused");
    check bool "a mismatched identity invokes no callback" false !callback_ran;
    let status, body = revoke config in
    check_status `Service_unavailable (status, body);
    check string "the route reports identity ambiguity" "credential_identity_mismatch"
      Yojson.Safe.Util.(member "code" body |> to_string);
    check string "the mismatched credential is not deleted" json (In_channel.with_open_text path In_channel.input_all);
    check (option string) "the held turn is not released" (Some "player") (controller ()))
    [ Masc_domain.Player; Masc_domain.Worker; Masc_domain.Admin ]

let test_renewal_before_revoke_preserves_current_role () =
  List.iter (fun initially_present ->
    with_machine @@ fun config _ _ ->
    if not initially_present then Auth.delete_credential config.base_path "player";
    let (new_token, _), response = interleave config
        (fun () -> renew_as_admin config) (fun () -> revoke config) in
    check_status `Conflict response;
    check string "the newly published Admin bearer survives the older revoke" "admin"
      (Masc_domain.agent_role_to_string
         (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:new_token)).role);
    check (option string) "neither an earlier Player nor absence read releases the renewed holder"
      (Some "player") (controller ())) [ true; false ]

let test_revoke_before_renewal_finishes_its_controller_effect () =
  List.iter (fun initially_present ->
    with_machine @@ fun config _ _ ->
    if not initially_present then Auth.delete_credential config.base_path "player";
    let response, (new_token, _) = interleave config
        (fun () -> revoke config)
        (fun () ->
          let renewed = renew_as_admin config in
          ignore (dos_ok (Dos_lane.step ~who:"player" ~steps:1 ~until_ready:false));
          renewed) in
    check_status `OK response;
    let body = snd response in
    check bool "the response distinguishes deletion from orphan recovery" initially_present
      Yojson.Safe.Util.(member "revoked" body |> to_bool);
    check bool "the old controller was released inside the revoke" true
      Yojson.Safe.Util.(member "released_controller" body |> to_bool);
    ignore (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:new_token));
    check (option string) "the old revoke cannot release the later renewed turn"
      (Some "player") (controller ())) [ true; false ]

let test_revoke_callback_holds_credential_admission () =
  with_machine @@ fun config _ _ ->
  let callback_entered, enter_callback = Eio.Promise.create () in
  let writer_done, finish_writer = Eio.Promise.create () in
  let revoked, finish_revoke = Eio.Promise.create () in
  let name = match Play_invite.Name.of_string "player" with
    | Ok name -> name | Error detail -> fail detail in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      let result = Play_invite.revoke ~base_path:config.base_path ~name
          ~after_revoke:(fun status ->
            check bool "deletion precedes the controller effect" true (status = Play_invite.Deleted);
            check bool "old credential already removed" true
              (Option.is_none (Auth.load_credential config.base_path "player"));
            Eio.Promise.resolve enter_callback ();
            await_waiter ~base_path:config.base_path writer_done;
            check bool "renewal cannot publish during the callback" true
              (Option.is_none (Eio.Promise.peek writer_done));
            ignore (dos_ok (Dos_lane.release_left ~holder:"player" ~announce:ignore))) in
      Eio.Promise.resolve finish_revoke result);
    Eio.Promise.await callback_entered;
    Eio.Fiber.fork ~sw (fun () ->
      let fresh = renew_as_admin config in
      ignore (dos_ok (Dos_lane.step ~who:"player" ~steps:1 ~until_ready:false));
      Eio.Promise.resolve finish_writer fresh);
    (match Eio.Promise.await revoked with
     | Ok () -> () | Error _ -> fail "revoke failed");
    ignore (Eio.Promise.await writer_done));
  check (option string) "renewed turn follows the completed revoke effect"
    (Some "player") (controller ())

let test_revoke_preserves_a_credentialless_keeper () =
  with_machine @@ fun config _ _ ->
  Auth.delete_credential config.base_path "player";
  let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "player"; "trace_id", `String "keeper-turn" ]) with
    | Ok meta -> meta
    | Error detail -> fail detail in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  check_status `Not_found (revoke config);
  check (option string) "a Keeper without a personal credential still owns its turn"
    (Some "player") (controller ())

let purge config =
  Server_dashboard_http_delete_actions.For_testing.purge_agent_artifacts config [ "player" ]

let purged = function Ok () -> () | Error detail -> fail detail

let uuid_path config (credential : Masc_domain.agent_credential) =
  match credential.id with
  | None -> fail "the purge fixture must be UUID-backed"
  | Some id -> Auth.credential_file config.Workspace.base_path (Masc_domain.Credential_id.to_string id)

let fresh_uuid_credential (old : Masc_domain.agent_credential) =
  let raw = Auth.generate_token () in
  raw, { old with id = Some (Masc_domain.Credential_id.generate ()); token = Auth.sha256_hash raw }

let test_purge_before_renewal_keeps_the_complete_new_credential () =
  with_machine @@ fun config _ _ ->
  let old_token, old = auth_ok (Auth.ensure_keeper_credential config.base_path ~agent_name:"player") in
  ignore (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:old_token));
  let new_token, fresh = fresh_uuid_credential old in
  let cleanup, () = interleave config (fun () -> purge config)
      (fun () -> Auth.save_credential config.base_path fresh) in
  purged cleanup;
  check bool "the prior UUID is retired" false (Sys.file_exists (uuid_path config old));
  check bool "the renewed UUID survives" true (Sys.file_exists (uuid_path config fresh));
  check (option string) "the renewed alias points at the same bearer"
    (Some fresh.token)
    (Option.map (fun (c : Masc_domain.agent_credential) -> c.token)
       (Auth.load_credential config.base_path "player"));
  check (list string) "listing sees one complete renewed identity" [ fresh.token ]
    (List.map (fun (c : Masc_domain.agent_credential) -> c.token) (Auth.list_credentials config.base_path));
  check string "the renewed bearer is usable through the normal lookup" "player"
    (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:new_token)).agent_name;
  check bool "the old cached bearer is retired" true
    (Result.is_error (Auth.find_static_credential_by_token config.base_path ~token:old_token))

let test_renewal_before_purge_removes_the_complete_current_credential () =
  with_machine @@ fun config _ _ ->
  let _, old = auth_ok (Auth.ensure_keeper_credential config.base_path ~agent_name:"player") in
  let new_token, fresh = fresh_uuid_credential old in
  let (), cleanup = interleave config
      (fun () -> Auth.save_credential config.base_path fresh) (fun () -> purge config) in
  purged cleanup;
  check bool "the alias is absent" false
    (Sys.file_exists (Auth.credential_file config.base_path "player"));
  List.iter (fun credential -> check bool "no UUID is orphaned" false
      (Sys.file_exists (uuid_path config credential))) [ old; fresh ];
  check bool "the raw-token sidecar is removed" false
    (Sys.file_exists (Auth.raw_token_file config.base_path "player"));
  check int "the complete store is empty" 0 (List.length (Auth.list_credentials config.base_path));
  check bool "the deleted renewal cannot authenticate" true
    (Result.is_error (Auth.find_static_credential_by_token config.base_path ~token:new_token))

let test_purge_revalidates_an_alias_after_admission () =
  with_machine @@ fun config _ _ ->
  let other_token, other = auth_ok
      (Auth.ensure_keeper_credential config.base_path ~agent_name:"other") in
  let alias_changed, cleanup = interleave config
      (fun () -> Auth.ensure_credential_alias config.base_path ~canonical_name:"other" ~alias_name:"player")
      (fun () -> purge config) in
  auth_ok alias_changed;
  check bool "the stale preflight cannot authorize another owner's deletion" true (Result.is_error cleanup);
  check bool "the unrelated owner's UUID remains" true (Sys.file_exists (uuid_path config other));
  check string "the unrelated bearer remains usable" "other"
    (auth_ok (Auth.find_static_credential_by_token config.base_path ~token:other_token)).agent_name

let test_failed_admission_moves_nothing () =
  with_machine @@ fun config _ _ ->
  let path = lock_path config.base_path in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  (match recover config with
   | Error (Keeper_dos_controller.Seats_unknown _) -> ()
   | Error (Keeper_dos_controller.Refused detail) -> fail detail
   | Ok () -> fail "recovery ran without the credential transaction");
  check (option string) "an unavailable credential lock preserves the holder" (Some "player") (controller ());
  let status, _ = Server_routes_http_routes_dos.press_into ~config ~who:"operator"
      ~saves_name:"spin.com" ~keys:[ "x" ] in
  check bool "the pad route refuses an unavailable credential transaction" true
    (status = `Service_unavailable);
  check_status `Service_unavailable (revoke config);
  check bool "a refused revoke retains the credential" true
    (Option.is_some (Auth.load_credential config.base_path "player"));
  check (option string) "the refused pad call cannot release ownership" (Some "player") (controller ())

let () =
  run "play_credential_transaction"
    [ "controller recovery",
      [ test_case "renewal before recovery preserves the turn" `Quick test_completed_renewal_preserves_the_controller
      ; test_case "recovery before renewal has one order" `Quick test_recovery_before_renewal_has_one_order
      ; test_case "cold index publication cannot undo renewal" `Quick test_cold_index_cannot_restore_credentials_after_renewal
      ; test_case "a cancelled delete releases admission" `Quick test_cancelled_delete_leaves_credential_and_releases_admission
      ; test_case "renewal before revoke preserves the current role" `Quick test_renewal_before_revoke_preserves_current_role
      ; test_case "renewal before issue preserves the current credential" `Quick test_renewal_before_issue_preserves_current_credential
      ; test_case "competing issues publish one invitation" `Quick test_competing_issues_publish_only_one_invite
      ; test_case "unreadable revoke preserves callbacks and controller" `Quick test_unreadable_revoke_preserves_effects
      ; test_case "unreadable recovery preserves the controller" `Quick test_unreadable_recovery_preserves_controller
      ; test_case "mismatched revoke preserves callbacks and controller" `Quick test_mismatched_revoke_preserves_effects
      ; test_case "revoke finishes before a renewed turn" `Quick test_revoke_before_renewal_finishes_its_controller_effect
      ; test_case "revoke callback excludes renewal after deletion" `Quick test_revoke_callback_holds_credential_admission
      ; test_case "revoke preserves a credentialless Keeper" `Quick test_revoke_preserves_a_credentialless_keeper
      ; test_case "purge before renewal keeps alias and UUID together" `Quick test_purge_before_renewal_keeps_the_complete_new_credential
      ; test_case "renewal before purge leaves no orphan" `Quick test_renewal_before_purge_removes_the_complete_current_credential
      ; test_case "purge revalidates the current alias owner" `Quick test_purge_revalidates_an_alias_after_admission
      ; test_case "failed admission moves nothing" `Quick test_failed_admission_moves_nothing ] ]
