(* The real credential publisher and DOS controller recovery contend on one
   transaction. No sleeps: the durable lock's admission hook fixes the order. *)
open Alcotest
open Masc

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
  let cancelled = auth_ok (Auth.with_credential_transaction config.base_path (fun () ->
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
  check (option string) "the refused pad call cannot release ownership" (Some "player") (controller ())

let () =
  run "play_credential_transaction"
    [ "controller recovery",
      [ test_case "renewal before recovery preserves the turn" `Quick test_completed_renewal_preserves_the_controller
      ; test_case "recovery before renewal has one order" `Quick test_recovery_before_renewal_has_one_order
      ; test_case "cold index publication cannot undo renewal" `Quick test_cold_index_cannot_restore_credentials_after_renewal
      ; test_case "a cancelled delete releases admission" `Quick test_cancelled_delete_leaves_credential_and_releases_admission
      ; test_case "failed admission moves nothing" `Quick test_failed_admission_moves_nothing ] ]
