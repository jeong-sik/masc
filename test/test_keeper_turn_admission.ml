(* Temporary non-waiting execution-fence tests. Keeper Owner owns scheduling
   and lifecycle shutdown admission. *)

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

let test_release_transition_is_observed () =
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
  check
    "turn release publishes once"
    (match !observed with
     | [ (observed_base, observed_keeper, Keeper_turn_admission.Turn_released) ] ->
       String.equal observed_base base_path
       && String.equal observed_keeper keeper_name
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

let () =
  Eio_main.run @@ fun _env ->
  test_selected_authority_rejection_has_zero_provider_dispatch ();
  test_same_keeper_is_non_waiting_busy ();
  test_distinct_keepers_do_not_block_each_other ();
  test_release_transition_is_observed ();
  test_exception_releases_slot ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_admission checks passed\n%!"
;;
