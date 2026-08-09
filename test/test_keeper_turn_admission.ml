(* Temporary execution/shutdown fence tests. Keeper Owner owns queueing and
   serialization; this module must never park a caller. *)

open Masc

let failures = ref 0

let check name cond =
  if cond
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec ensure_dir path =
  if not (Sys.file_exists path)
  then (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let base_path = "/tmp/masc_test_turn_admission"
let keeper_name = "admission-keeper"

let reset () =
  Keeper_turn_admission.For_testing.reset ();
  remove_tree base_path;
  ensure_dir base_path
;;

let test_selected_authority_rejection_has_zero_provider_dispatch () =
  reset ();
  let dispatch_count = ref 0 in
  let captured_token = ref None in
  (match
     Keeper_turn_admission.run_if_free_with_token
       ~base_path
       ~keeper_name
       (fun token ->
          captured_token := Some token;
          (match
             Keeper_turn_admission.install_before_dispatch_authority
               token
               (fun () -> Error "selected pending source changed")
           with
           | Ok () -> ()
           | Error _ -> check "dispatch authority installs once" false);
          Keeper_unified_turn_execution.run_provider_dispatch_if_authorized
            ~before_dispatch_authority:
              (fun () -> Keeper_turn_admission.validate_before_dispatch token)
            (fun () ->
               incr dispatch_count;
               Ok ()))
   with
   | `Ran (Error _) -> check "authority failure is typed" true
   | `Ran (Ok ()) | `Busy _ -> check "authority failure is typed" false);
  check "provider dispatch closure was not called" (!dispatch_count = 0);
  match !captured_token with
  | None -> check "released token was captured" false
  | Some token ->
    check
      "released token cannot dispatch"
      (Result.is_error (Keeper_turn_admission.validate_before_dispatch token))
;;

let test_same_keeper_is_non_waiting_busy () =
  reset ();
  match
    Keeper_turn_admission.run_if_free
      ~base_path
      ~keeper_name
      (fun () ->
         Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()))
  with
  | `Ran (`Busy (Keeper_turn_admission.Turn_busy _)) ->
    check "same Keeper returns Busy without parking" true
  | `Ran (`Busy _) | `Ran (`Ran ()) | `Busy _ ->
    check "same Keeper returns Busy without parking" false
;;

let test_distinct_keepers_do_not_block_each_other () =
  reset ();
  let keeper_a = keeper_name ^ "-a" in
  let keeper_b = keeper_name ^ "-b" in
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      match
        Keeper_turn_admission.run_if_free
          ~base_path
          ~keeper_name:keeper_a
          (fun () ->
             Eio.Promise.resolve set_started ();
             Eio.Promise.await release)
      with
      | `Ran () -> ()
      | `Busy _ -> check "first Keeper turn admits" false);
    Eio.Promise.await started;
    (match
       Keeper_turn_admission.run_if_free
         ~base_path
         ~keeper_name:keeper_b
         (fun () -> true)
     with
     | `Ran true -> check "different Keeper runs concurrently" true
     | `Ran false | `Busy _ -> check "different Keeper runs concurrently" false);
    Eio.Promise.resolve set_release ())
;;

let test_dispatchability_transitions_are_observed () =
  reset ();
  let observed = ref [] in
  Keeper_turn_admission.set_slot_transition_observer
    (Some
       (fun ~base_path:observed_base_path ~keeper_name:observed_keeper
            ~transition ->
          observed :=
            (observed_base_path, observed_keeper, transition) :: !observed));
  ignore
    (Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ())
      : [ `Ran of unit | `Busy of Keeper_turn_admission.autonomous_block ]);
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  ignore
    (Keeper_turn_admission.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
      : Keeper_turn_admission.begin_shutdown_result);
  ignore
    (Keeper_turn_admission.rollback_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
      : Keeper_turn_admission.rollback_shutdown_result);
  let observed = List.rev !observed in
  check
    "turn release and shutdown rollback both publish"
    (match observed with
     | [ (turn_base, turn_keeper, Keeper_turn_admission.Turn_released)
       ; (rollback_base, rollback_keeper, Keeper_turn_admission.Shutdown_rolled_back)
       ] ->
       String.equal turn_base base_path
       && String.equal rollback_base base_path
       && String.equal turn_keeper keeper_name
       && String.equal rollback_keeper keeper_name
     | _ -> false);
  Keeper_turn_admission.set_slot_transition_observer None
;;

let test_exception_releases_slot () =
  reset ();
  (try
     ignore
       (Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () ->
          failwith "boom"))
   with
   | Failure _ -> ());
  match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
  | `Ran () -> check "slot releases after exception" true
  | `Busy _ -> check "slot releases after exception" false
;;

let test_shutdown_reservation_fences_and_rolls_back () =
  reset ();
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_turn_admission.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_reserved reservation ->
     check
       "reservation records typed operation"
       (Keeper_shutdown_types.Operation_id.equal reservation.operation_id operation_id);
     check "idle reservation has no in-flight turn" (Option.is_none reservation.in_flight)
   | Keeper_turn_admission.Shutdown_already_reserved _ ->
     check "fresh slot is not already reserved" false);
  (match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> ()) with
   | `Busy (Keeper_turn_admission.Shutdown_requested reserved) ->
     check
       "turn sees typed shutdown fence"
       (Keeper_shutdown_types.Operation_id.equal reserved operation_id)
   | `Busy (Keeper_turn_admission.Turn_busy _) | `Ran () ->
     check "turn cannot cross shutdown fence" false);
  (match
     Keeper_turn_admission.rollback_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_rolled_back -> ()
   | Keeper_turn_admission.Shutdown_not_reserved
   | Keeper_turn_admission.Shutdown_reserved_by_other _ ->
     check "own reservation rolls back" false);
  match Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () -> "open") with
  | `Ran "open" -> check "rollback re-opens admission" true
  | `Ran _ | `Busy _ -> check "rollback re-opens admission" false
;;

let test_shutdown_reservation_restores_durable_owner () =
  reset ();
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  let other_operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_turn_admission.restore_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_restored -> ()
   | Keeper_turn_admission.Shutdown_already_restored
   | Keeper_turn_admission.Shutdown_restore_conflict _ ->
     check "fresh durable owner restores" false);
  (match
     Keeper_turn_admission.restore_shutdown
       ~base_path
       ~keeper_name
       ~operation_id:other_operation_id
   with
   | Keeper_turn_admission.Shutdown_restore_conflict existing ->
     check
       "different durable owner cannot replace fence"
       (Keeper_shutdown_types.Operation_id.equal existing operation_id)
   | Keeper_turn_admission.Shutdown_restored
   | Keeper_turn_admission.Shutdown_already_restored ->
     check "different durable owner is rejected" false);
  match
    Keeper_turn_admission.commit_registration_if_open
      ~base_path
      ~keeper_name
      (fun () -> ())
  with
  | Keeper_turn_admission.Registration_shutdown_reserved existing ->
    check
      "registration sees restored durable owner"
      (Keeper_shutdown_types.Operation_id.equal existing operation_id)
  | Keeper_turn_admission.Registration_committed () ->
    check "registration cannot cross restored fence" false
;;

let test_unknown_rollback_does_not_create_admission_slot () =
  reset ();
  let owner = "owner-without-admission-slot" in
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_turn_admission.rollback_shutdown
       ~base_path
       ~keeper_name:owner
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_not_reserved ->
     check "unknown owner returns not reserved" true
   | Keeper_turn_admission.Shutdown_rolled_back
   | Keeper_turn_admission.Shutdown_reserved_by_other _ ->
     check "unknown owner returns not reserved" false);
  let snapshot = Keeper_turn_admission.snapshot_for ~base_path ~keeper_name:owner in
  check "unknown rollback leaves no slot" (not snapshot.snapshot_slot_created)
;;

let test_health_has_no_chat_waiter_contract () =
  reset ();
  let json =
    Keeper_turn_admission.fleet_health_json
      ~base_path
      ~keeper_names:[ keeper_name ]
  in
  let open Yojson.Safe.Util in
  check "fleet health has no chat waiter total"
    (json |> member "chat_waiting_total_count" = `Null);
  let keeper = json |> member "keepers" |> to_list |> List.hd in
  check "slot health has no chat waiter count"
    (keeper |> member "chat_waiting_count" = `Null)
;;

let () =
  Eio_main.run @@ fun _env ->
  test_selected_authority_rejection_has_zero_provider_dispatch ();
  test_same_keeper_is_non_waiting_busy ();
  test_distinct_keepers_do_not_block_each_other ();
  test_dispatchability_transitions_are_observed ();
  test_exception_releases_slot ();
  test_shutdown_reservation_fences_and_rolls_back ();
  test_shutdown_reservation_restores_durable_owner ();
  test_unknown_rollback_does_not_create_admission_slot ();
  test_health_has_no_chat_waiter_contract ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_admission checks passed\n%!"
;;
