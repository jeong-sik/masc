open Alcotest

module Mutation = Fs_compat.Durable_mutation

let segment value =
  match Mutation.Segment.of_string value with
  | Ok value -> value
  | Error _ -> failf "invalid test segment: %S" value
;;

let progress_testable =
  testable
    (fun formatter -> function
       | `Not_committed -> Format.pp_print_string formatter "Not_committed"
       | `Committed_not_durable ->
         Format.pp_print_string formatter "Committed_not_durable"
       | `Durable -> Format.pp_print_string formatter "Durable")
    ( = )
;;

let check_progress expected report =
  let actual =
    match report.Mutation.progress with
    | Mutation.Not_committed _ -> `Not_committed
    | Mutation.Committed_not_durable _ -> `Committed_not_durable
    | Mutation.Durable () -> `Durable
  in
  check progress_testable "mutation progress" expected actual
;;

let test_segment_boundary () =
  List.iter
    (fun value ->
      check bool value true (Result.is_error (Mutation.Segment.of_string value)))
    [ ""; "."; ".."; "a/b"; "a\000b" ];
  check bool "plain child accepted" true
    (Result.is_ok (Mutation.Segment.of_string "state.json"))
;;

let test_prepare_failure_is_not_committed () =
  let cleanup_calls = ref 0 in
  let report =
    Mutation.For_testing.run_state_machine
      ~prepare:(fun () -> raise Exit)
      ~commit:(fun () -> fail "commit must not run")
      ~publish:(fun () -> fail "publish must not run")
      ~cleanup:(fun () -> incr cleanup_calls; [])
  in
  check_progress `Not_committed report;
  check int "cleanup once" 1 !cleanup_calls
;;

let test_commit_failure_is_not_committed () =
  let cleanup_calls = ref 0 in
  let report =
    Mutation.For_testing.run_state_machine
      ~prepare:ignore
      ~commit:(fun () -> raise Exit)
      ~publish:(fun () -> fail "publish must not run")
      ~cleanup:(fun () -> incr cleanup_calls; [])
  in
  check_progress `Not_committed report;
  check int "cleanup once" 1 !cleanup_calls
;;

let test_cancellation_after_commit_preserves_committed_state () =
  let cleanup_calls = ref 0 in
  let report =
    Mutation.For_testing.run_state_machine
      ~prepare:ignore
      ~commit:ignore
      ~publish:(fun () ->
        raise (Eio.Cancel.Cancelled (Failure "cancel after rename")))
      ~cleanup:(fun () -> incr cleanup_calls; [])
  in
  check_progress `Committed_not_durable report;
  check int "committed entry is never cleaned up" 0 !cleanup_calls
;;

let test_observer_failure_is_separate () =
  let report =
    Mutation.For_testing.run_state_machine
      ~prepare:ignore
      ~commit:ignore
      ~publish:ignore
      ~cleanup:(fun () -> [])
  in
  match Mutation.observe (fun _ -> raise Exit) report with
  | Mutation.Observed -> fail "observer failure was not reported"
  | Mutation.Observer_failed diagnostic ->
    check bool "observer diagnostic" true
      (diagnostic.Mutation.stage = Mutation.Observer);
    check_progress `Durable report
;;

let test_observer_cancellation_propagates () =
  let report =
    Mutation.For_testing.run_state_machine
      ~prepare:ignore
      ~commit:ignore
      ~publish:ignore
      ~cleanup:(fun () -> [])
  in
  match
    Mutation.observe
      (fun _ -> raise (Eio.Cancel.Cancelled (Failure "observer cancelled")))
      report
  with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Mutation.Observed | Mutation.Observer_failed _ ->
    fail "observer swallowed Eio cancellation"
;;

let test_observer_failure_is_retained_as_diagnostic () =
  let report =
    Mutation.For_testing.run_state_machine
      ~prepare:ignore
      ~commit:ignore
      ~publish:ignore
      ~cleanup:(fun () -> [])
  in
  let report = Mutation.observe_and_retain (fun _ -> raise Exit) report in
  check_progress `Durable report;
  match report.Mutation.diagnostics with
  | [ diagnostic ] ->
    check bool "observer diagnostic retained" true
      (diagnostic.Mutation.stage = Mutation.Observer)
  | diagnostics ->
    failf "expected one observer diagnostic, got %d" (List.length diagnostics)
;;

let test_confirmation_observer_failure_is_retained_as_diagnostic () =
  let report =
    { Mutation.confirmation = Mutation.Confirmed; confirmation_diagnostics = [] }
  in
  let report =
    Mutation.observe_confirmation_and_retain (fun _ -> raise Exit) report
  in
  check bool "confirmation retained" true
    (report.Mutation.confirmation = Mutation.Confirmed);
  match report.Mutation.confirmation_diagnostics with
  | [ diagnostic ] ->
    check bool "confirmation observer diagnostic retained" true
      (diagnostic.Mutation.stage = Mutation.Observer)
  | diagnostics ->
    failf "expected one confirmation observer diagnostic, got %d"
      (List.length diagnostics)
;;

let with_temp_dir f =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "durable_mutation_%d_%08x"
         (Unix.getpid ())
         (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    (fun () -> f path)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let test_real_blocking_replace () =
  with_temp_dir (fun parent ->
    let name = segment "state.json" in
    let path = Filename.concat parent "state.json" in
    let first =
      Mutation.atomic_replace_blocking
        ~parent
        ~name
        ~perm:0o600
        "first"
    in
    check_progress `Durable first;
    let second =
      Mutation.atomic_replace_blocking
        ~parent
        ~name
        ~perm:0o600
        "second"
    in
    check_progress `Durable second;
    check string "replacement visible" "second" (read_file path);
    check int "no temporary residue" 1 (Array.length (Sys.readdir parent)))
;;

let test_directory_durability_confirmation () =
  with_temp_dir (fun parent ->
    let report = Mutation.confirm_directory_durable_blocking parent in
    (match report.confirmation with
     | Mutation.Confirmed -> ()
    | Mutation.Not_confirmed _ -> fail "existing directory was not confirmed");
    check (list string) "no close diagnostics" []
      (List.map
         Mutation.diagnostic_to_string
         report.confirmation_diagnostics))
;;

let test_missing_directory_durability_not_confirmed () =
  with_temp_dir (fun parent ->
    let missing = Filename.concat parent "missing" in
    let report = Mutation.confirm_directory_durable_blocking missing in
    match report.confirmation with
    | Mutation.Not_confirmed _ -> ()
    | Mutation.Confirmed -> fail "missing directory was confirmed")
;;

let test_parent_symlink_is_rejected () =
  with_temp_dir (fun root ->
    let real_parent = Filename.concat root "real" in
    let linked_parent = Filename.concat root "linked" in
    Unix.mkdir real_parent 0o700;
    Unix.symlink real_parent linked_parent;
    let report =
      Mutation.atomic_replace_blocking
        ~parent:linked_parent
        ~name:(segment "state.json")
        ~perm:0o600
        "blocked"
    in
    check_progress `Not_committed report;
    check bool "real directory untouched" false
      (Sys.file_exists (Filename.concat real_parent "state.json"));
    Unix.unlink linked_parent;
    Unix.rmdir real_parent)
;;

let test_final_symlink_is_replaced_not_followed () =
  with_temp_dir (fun parent ->
    let outside = Filename.concat parent "outside.json" in
    let target = Filename.concat parent "state.json" in
    let channel = open_out_bin outside in
    output_string channel "outside";
    close_out channel;
    Unix.symlink outside target;
    let report =
      Mutation.atomic_replace_blocking
        ~parent
        ~name:(segment "state.json")
        ~perm:0o600
        "inside"
    in
    check_progress `Durable report;
    check string "outside inode untouched" "outside" (read_file outside);
    check string "target entry replaced" "inside" (read_file target))
;;

let test_eio_boundary_returns_report () =
  with_temp_dir (fun parent ->
    Eio_main.run @@ fun _env ->
    let report =
      Mutation.atomic_replace_eio
        ~parent
        ~name:(segment "state.json")
        ~perm:0o600
        "eio"
    in
    check_progress `Durable report)
;;

let test_confirmation_eio_boundary_returns_report () =
  with_temp_dir (fun parent ->
    Eio_main.run @@ fun _env ->
    let report = Mutation.confirm_directory_durable_eio parent in
    check bool "directory durability confirmed" true
      (report.Mutation.confirmation = Mutation.Confirmed))
;;

let () =
  run
    "durable-mutation-state-machine"
    [ ( "contract"
      , [ test_case "segment boundary" `Quick test_segment_boundary
        ; test_case
            "prepare failure is not committed"
            `Quick
            test_prepare_failure_is_not_committed
        ; test_case
            "commit failure is not committed"
            `Quick
            test_commit_failure_is_not_committed
        ; test_case
            "cancellation after commit preserves state"
            `Quick
            test_cancellation_after_commit_preserves_committed_state
        ; test_case
            "observer failure is separate"
            `Quick
            test_observer_failure_is_separate
        ; test_case
            "observer cancellation propagates"
            `Quick
            test_observer_cancellation_propagates
        ; test_case
            "observer failure is retained"
            `Quick
            test_observer_failure_is_retained_as_diagnostic
        ; test_case
            "confirmation observer failure is retained"
            `Quick
            test_confirmation_observer_failure_is_retained_as_diagnostic
        ; test_case "blocking replace" `Quick test_real_blocking_replace
        ; test_case
            "directory durability confirmation"
            `Quick
            test_directory_durability_confirmation
        ; test_case
            "missing directory is not confirmed"
            `Quick
            test_missing_directory_durability_not_confirmed
        ; test_case
            "parent symlink rejected"
            `Quick
            test_parent_symlink_is_rejected
        ; test_case
            "final symlink replaced"
            `Quick
            test_final_symlink_is_replaced_not_followed
        ; test_case "Eio boundary" `Quick test_eio_boundary_returns_report
        ; test_case
            "confirmation Eio boundary"
            `Quick
            test_confirmation_eio_boundary_returns_report
        ] )
    ]
