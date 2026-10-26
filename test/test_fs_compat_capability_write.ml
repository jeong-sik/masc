open Alcotest

module Capability_write_test =
  Fs_compat_test_support.Capability_write_for_testing

let with_tmp_dir f =
  let path = Filename.temp_file "masc_capability_write_" ".tmp" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let directory_entries directory =
  Sys.readdir directory |> Array.to_list |> List.sort String.compare
;;

let only_entry_except directory excluded =
  match List.filter (fun entry -> not (List.mem entry excluded)) (directory_entries directory) with
  | [ entry ] -> entry
  | entries ->
    failf
      "expected one unlisted directory entry, got [%s]"
      (String.concat "; " entries)
;;

let with_parent_capability ~fs directory f =
  Eio.Path.with_open_dir Eio.Path.(fs / directory) f
;;

let with_publication_recovery_access ~fs f =
  with_tmp_dir @@ fun registry_directory ->
  Eio.Switch.run @@ fun sw ->
  match
    Fs_compat.Publication_recovery.open_registry
      ~sw
      ~fs
      ~registry_root:Eio.Path.(fs / registry_directory)
  with
  | Error error ->
    fail (Fs_compat.Publication_recovery.registry_error_to_string error)
  | Ok registry ->
    (match Fs_compat.Publication_recovery.discover_owners registry with
     | Error error ->
       fail
         (Fs_compat.Publication_recovery.discovery_error_to_string
            error)
     | Ok [] ->
       (match
          Fs_compat.Publication_recovery.with_lane
            ~registry
            ~owner:"capability-write-test"
            f
        with
        | Ok (Fs_compat.Publication_recovery.Lane_released value) -> value
        | Ok (Fs_compat.Publication_recovery.Lane_release_failed _) ->
          fail "publication recovery lane release failed"
        | Error error ->
          fail
            (Fs_compat.Publication_recovery.lane_open_error_to_string
               error))
     | Ok rows ->
       failf
         "fresh publication recovery fixture unexpectedly contained owners: %s"
         (String.concat
            "; "
            (List.map
               Fs_compat.Publication_recovery.owner_discovery_row_to_string
               rows)))
;;

let with_replace_context ~fs directory f =
  with_parent_capability ~fs directory @@ fun parent ->
  with_publication_recovery_access ~fs @@ fun recovery ->
  f parent recovery
;;

let require_recovery_target ~allowed_root_path ~parent ~leaf ~permissions =
  let root = Eio.Path.stat ~follow:true parent in
  match
    Fs_compat.capability_publication_target
      ~allowed_root_path
      ~allowed_root_device:root.dev
      ~allowed_root_inode:root.ino
      ~parent_components:[]
      ~target_leaf:leaf
      ~permissions
  with
  | Ok target -> target
  | Error error ->
    fail (Fs_compat.capability_publication_target_error_to_string error)
;;

let replace_capability_file ~recovery ~allowed_root_path ~parent ~leaf ~permissions content =
  let target =
    require_recovery_target ~allowed_root_path ~parent ~leaf ~permissions
  in
  Fs_compat.replace_capability_file ~recovery ~parent ~target content
;;

let replace_capability_file_for_testing
      ~before_stage
      ~recovery
      ~allowed_root_path
      ~parent
      ~leaf
      ~permissions
      content
  =
  let target =
    require_recovery_target ~allowed_root_path ~parent ~leaf ~permissions
  in
  Capability_write_test.replace_capability_file
    ~before_stage
    ~recovery
    ~parent
    ~target
    content
;;

let create_capability_file ~recovery ~allowed_root_path ~parent ~leaf ~permissions content =
  let target = require_recovery_target ~allowed_root_path ~parent ~leaf ~permissions in
  Fs_compat.create_capability_file_exclusive ~recovery ~parent ~target content
;;

let create_capability_file_for_testing ~before_stage ~recovery ~allowed_root_path ~parent ~leaf ~permissions content =
  let target = require_recovery_target ~allowed_root_path ~parent ~leaf ~permissions in
  Capability_write_test.create_capability_file_exclusive ~before_stage ~recovery ~parent ~target content
;;

let test_standalone_exclusive_publication ~fs () =
  with_tmp_dir @@ fun directory ->
  let create leaf content =
    Fs_compat.create_file_exclusive ~fs ~owner:"standalone-export-test"
      ~path:(Filename.concat directory leaf) ~permissions:0o600 content
  in
  let require_created = function Ok () -> () | Error detail -> fail detail in
  require_created (create "original" "exact bytes\000\r\n");
  check string "standalone exact payload" "exact bytes\000\r\n"
    (read_file (Filename.concat directory "original"));
  check int "standalone private mode" 0o600
    ((Unix.stat (Filename.concat directory "original")).Unix.st_perm land 0o777);
  (match create "original" "overwrite" with
   | Error _ -> () | Ok () -> fail "standalone export overwrote existing file");
  Unix.symlink "original" (Filename.concat directory "alias");
  (match create "alias" "overwrite" with
   | Error _ -> () | Ok () -> fail "standalone export overwrote a symlink");
  check string "standalone original survives" "exact bytes\000\r\n"
    (read_file (Filename.concat directory "original"));
  require_created (create "next" "same stable lane after reopen");
  check string "standalone restart uses original owner" "same stable lane after reopen"
    (read_file (Filename.concat directory "next"))
;;

let require_write_primary_failure (error : Fs_compat.capability_write_error) =
  match error.primary_failure with
  | Fs_compat.Write_primary_failure failure -> failure
  | Fs_compat.Recovery_primary_failure failure ->
    fail (Fs_compat.capability_recovery_failure_to_string failure)
  | Fs_compat.Recovery_access_primary_failure _ ->
    fail "publication recovery access unexpectedly unavailable"
;;

let has_write_cleanup_stage stage (error : Fs_compat.capability_write_error) =
  List.exists
    (function
      | Fs_compat.Write_cleanup_failure failure -> failure.stage = stage
      | Fs_compat.Recovery_cleanup_failure _ -> false)
    error.cleanup_failures
;;

let require_ok = function
  | Ok () -> ()
  | Error error -> fail (Fs_compat.capability_write_error_to_string error)
;;

let require_append_file = function
  | Ok file -> file
  | Error error -> fail (Fs_compat.capability_append_open_error_to_string error)
;;

let nonrecoverable_write_exceptions () =
  [ "out_of_memory", Out_of_memory
  ; "stack_overflow", Stack_overflow
  ; "sys_break", Sys.Break
  ; "cancellation", Eio.Cancel.Cancelled Exit
  ]
;;

(* Propagation may append Eio re-raise frames. Every injected frame, including
   its origin, must still survive unchanged and in order at the start. *)
let check_preserved_backtrace ~label expected observed =
  let length = Printexc.raw_backtrace_length expected in
  check bool (label ^ " injected trace has an origin") true (length > 0);
  check bool (label ^ " preserves original trace length") true
    (Printexc.raw_backtrace_length observed >= length);
  for index = 0 to length - 1 do
    check bool (Printf.sprintf "%s preserves original frame %d" label index) true
      (Printexc.get_raw_backtrace_slot expected index
       = Printexc.get_raw_backtrace_slot observed index)
  done
;;

let check_same_exception_and_backtrace
      ~label
      ~expected_exception
      ~expected_backtrace
      operation
  =
  let observed =
    try
      operation ();
      None
    with
    | exception_ ->
      Some (exception_, Printexc.get_raw_backtrace ())
  in
  match observed with
  | None -> failf "%s unexpectedly entered the typed result channel" label
  | Some (exception_, backtrace) ->
    check bool (label ^ " preserves exception identity") true
      (exception_ == expected_exception);
    check_preserved_backtrace ~label expected_backtrace backtrace
;;

let test_replace_nonrecoverable_exceptions_preserve_backtrace ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  List.iter
    (fun (name, exception_) ->
       let backtrace = Printexc.get_callstack 32 in
       check_same_exception_and_backtrace
         ~label:("replace " ^ name)
         ~expected_exception:exception_
         ~expected_backtrace:backtrace
         (fun () ->
            ignore
              (replace_capability_file_for_testing
                 ~before_stage:(function
                   | Fs_compat.Acquire_mutation_lease ->
                     Printexc.raise_with_backtrace exception_ backtrace
                   | _ -> ())
                 ~recovery
                 ~allowed_root_path:directory
                 ~parent
                 ~leaf:"target"
                 ~permissions:0o640
                 "new"
               : (unit, Fs_compat.capability_write_error) result)))
    (nonrecoverable_write_exceptions ());
  check string "fatal replace attempts leave target unchanged" "old"
    (read_file target)
;;

let test_create_nonrecoverable_exceptions_preserve_backtrace ~fs () =
  with_tmp_dir @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  List.iter
    (fun (name, exception_) ->
       let backtrace = Printexc.get_callstack 32 in
       check_same_exception_and_backtrace
         ~label:("exclusive create " ^ name)
         ~expected_exception:exception_
         ~expected_backtrace:backtrace
         (fun () ->
            ignore
              (create_capability_file_for_testing ~recovery ~allowed_root_path:directory
                 ~before_stage:(function
                   | Fs_compat.Inspect_target_entry ->
                     Printexc.raise_with_backtrace exception_ backtrace
                   | _ -> ())
                 ~parent
                 ~leaf:"target"
                 ~permissions:0o640
                 "new"
               : (unit, Fs_compat.capability_write_error) result)))
    (nonrecoverable_write_exceptions ());
  check bool "fatal create attempts do not publish target" false
    (Sys.file_exists (Filename.concat directory "target"))
;;

let test_cleanup_fatal_exception_preserves_backtrace ~fs () =
  with_tmp_dir @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  List.iter
    (fun (name, fatal) ->
       let backtrace = Printexc.get_callstack 32 in
       check_same_exception_and_backtrace
         ~label:("exclusive create cleanup " ^ name)
         ~expected_exception:fatal
         ~expected_backtrace:backtrace
         (fun () ->
            ignore
              (create_capability_file_for_testing ~recovery ~allowed_root_path:directory
                 ~before_stage:(function
                   | Fs_compat.Write_payload -> raise Exit
                   | Fs_compat.Cleanup_close ->
                     Printexc.raise_with_backtrace fatal backtrace
                   | _ -> ())
                 ~parent
                 ~leaf:("target-" ^ name)
                 ~permissions:0o640
                 "new"
               : (unit, Fs_compat.capability_write_error) result)))
    [ "out_of_memory", Out_of_memory
    ; "stack_overflow", Stack_overflow
    ; "sys_break", Sys.Break
    ]
;;

let require_capability_write_cancellation ~label operation =
  try
    operation ();
    failf "%s cancellation was swallowed" label
  with
  | Eio.Cancel.Cancelled
      (Fs_compat.Capability_write_cancelled (reason, cancellation)) ->
    reason, cancellation, Printexc.get_raw_backtrace ()
  | Eio.Cancel.Cancelled _ ->
    failf "%s cancellation lost capability-write authority" label
;;

let check_interrupted_write_stage
      ~label
      ~expected_stage
      (cancellation : Fs_compat.capability_write_cancellation)
  =
  match cancellation.interrupted_primary_failure with
  | Some (Fs_compat.Write_primary_failure failure) ->
    check bool (label ^ " preserves interrupted primary stage") true
      (failure.stage = expected_stage)
  | Some (Fs_compat.Recovery_primary_failure failure) ->
    fail (Fs_compat.capability_recovery_failure_to_string failure)
  | Some (Fs_compat.Recovery_access_primary_failure _) ->
    failf "%s replaced the write primary with recovery access" label
  | None -> failf "%s omitted the interrupted write primary" label
;;

let check_cancellation_cleanup_stages
      ~label
      ~expected_cleanup_stages
      (cancellation : Fs_compat.capability_write_cancellation)
  =
  let cleanup_stages =
    List.map
      (function
        | Fs_compat.Write_cleanup_failure failure -> failure.stage
        | Fs_compat.Recovery_cleanup_failure failure ->
          fail (Fs_compat.capability_recovery_failure_to_string failure))
      cancellation.cleanup_failures
  in
  check bool (label ^ " preserves exact cleanup failures") true
    (cleanup_stages = expected_cleanup_stages)
;;

let check_direct_cleanup_cancellation
      ~label
      ~reason
      ~backtrace
      ~expected_operation
      ~expected_target_effect
      ~expected_primary_stage
      ~expected_cleanup_stages
      operation
  =
  let observed_reason, cancellation, observed_backtrace =
    require_capability_write_cancellation ~label operation
  in
  check bool (label ^ " preserves reason identity") true
    (observed_reason == reason);
  check_preserved_backtrace ~label backtrace observed_backtrace;
  check bool (label ^ " preserves operation") true
    (cancellation.operation = expected_operation);
  check bool (label ^ " preserves target effect") true
    (cancellation.target_effect = expected_target_effect);
  check bool (label ^ " has no invented recovery interruption") true
    (Option.is_none cancellation.interrupted_recovery);
  check_interrupted_write_stage
    ~label
    ~expected_stage:expected_primary_stage
    cancellation;
  check_cancellation_cleanup_stages ~label ~expected_cleanup_stages cancellation
;;

let test_replace_direct_cleanup_cancellation_preserves_authority ~fs () =
  let run
        ~label
        ~primary_stage
        ~cleanup_stage
        ~expected_target_effect
    =
    with_tmp_dir @@ fun directory ->
    let target = Filename.concat directory "target" in
    write_file target "old";
    with_replace_context ~fs directory @@ fun parent recovery ->
    let reason = Failure label in
    let backtrace = Printexc.get_callstack 32 in
    check_direct_cleanup_cancellation
      ~label
      ~reason
      ~backtrace
      ~expected_operation:Fs_compat.Atomic_replace_operation
      ~expected_target_effect
      ~expected_primary_stage:primary_stage
      ~expected_cleanup_stages:[]
      (fun () ->
         ignore
           (replace_capability_file_for_testing
              ~before_stage:(fun stage ->
                if stage = primary_stage
                then raise Exit
                else if stage = cleanup_stage
                then
                  Printexc.raise_with_backtrace
                    (Eio.Cancel.Cancelled reason)
                    backtrace)
              ~recovery
              ~allowed_root_path:directory
              ~parent
              ~leaf:"target"
              ~permissions:0o640
              "new"
            : (unit, Fs_compat.capability_write_error) result))
  in
  run
    ~label:"replace unchanged cleanup"
    ~primary_stage:Fs_compat.Write_payload
    ~cleanup_stage:Fs_compat.Cleanup_close
    ~expected_target_effect:Fs_compat.Target_unchanged;
  run
    ~label:"replace published cleanup"
    ~primary_stage:Fs_compat.Sync_parent
    ~cleanup_stage:Fs_compat.Cleanup_sync_parent
    ~expected_target_effect:Fs_compat.Target_replaced
;;

let test_create_direct_cleanup_cancellation_preserves_authority ~fs () =
  let run
        ~label
        ~primary_stage
        ~cleanup_stage
        ~expected_target_effect
    =
    with_tmp_dir @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    let reason = Failure label in
    let backtrace = Printexc.get_callstack 32 in
    check_direct_cleanup_cancellation
      ~label
      ~reason
      ~backtrace
      ~expected_operation:Fs_compat.Create_exclusive_operation
      ~expected_target_effect
      ~expected_primary_stage:primary_stage
      ~expected_cleanup_stages:[]
      (fun () ->
         ignore
           (create_capability_file_for_testing ~recovery ~allowed_root_path:directory
              ~before_stage:(fun stage ->
                if stage = primary_stage
                then raise Exit
                else if stage = cleanup_stage
                then
                  Printexc.raise_with_backtrace
                    (Eio.Cancel.Cancelled reason)
                    backtrace)
              ~parent
              ~leaf:"target"
              ~permissions:0o640
              "new"
            : (unit, Fs_compat.capability_write_error) result))
  in
  run
    ~label:"create private cleanup"
    ~primary_stage:Fs_compat.Write_payload
    ~cleanup_stage:Fs_compat.Cleanup_close
    ~expected_target_effect:Fs_compat.Target_unchanged;
  run
    ~label:"create complete cleanup"
    ~primary_stage:Fs_compat.Sync_parent
    ~cleanup_stage:Fs_compat.Cleanup_sync_parent
    ~expected_target_effect:Fs_compat.Target_created
;;

let test_replace_cleanup_cancellation_retains_earlier_cleanup_failure ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let label = "replace cancellation after failed staging unlink" in
  let reason = Failure label in
  let backtrace = Printexc.get_callstack 32 in
  check_direct_cleanup_cancellation
    ~label
    ~reason
    ~backtrace
    ~expected_operation:Fs_compat.Atomic_replace_operation
    ~expected_target_effect:Fs_compat.Target_unchanged
    ~expected_primary_stage:Fs_compat.Write_payload
    ~expected_cleanup_stages:[ Fs_compat.Cleanup_unlink ]
    (fun () ->
       ignore
         (replace_capability_file_for_testing
            ~before_stage:(function
              | Fs_compat.Write_payload | Fs_compat.Cleanup_unlink -> raise Exit
              | Fs_compat.Cleanup_close_staging_directory ->
                Printexc.raise_with_backtrace
                  (Eio.Cancel.Cancelled reason)
                  backtrace
              | _ -> ())
            ~recovery
            ~allowed_root_path:directory
            ~parent
            ~leaf:"target"
            ~permissions:0o640
            "new"
          : (unit, Fs_compat.capability_write_error) result));
  check string "cancelled replacement leaves original payload" "old"
    (read_file target);
  let stage = only_entry_except directory [ "target" ] in
  check string "failed unlink leaves staging payload observable" ""
    (read_file (Filename.concat (Filename.concat directory stage) "payload"))
;;

let test_cancelled_replace_retains_cleanup_facts_on_second_cancellation ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let label = "cancelled replacement with cancelled cleanup" in
  let reason = Failure "original payload cancellation" in
  let cleanup_reason = Failure "later cleanup cancellation" in
  let backtrace = Printexc.get_callstack 32 in
  let observed_reason, cancellation, observed_backtrace =
    require_capability_write_cancellation ~label (fun () ->
      ignore
        (replace_capability_file_for_testing
           ~before_stage:(function
             | Fs_compat.Write_payload ->
               Printexc.raise_with_backtrace
                 (Eio.Cancel.Cancelled reason)
                 backtrace
             | Fs_compat.Cleanup_unlink -> raise Exit
             | Fs_compat.Cleanup_close_staging_directory ->
               raise (Eio.Cancel.Cancelled cleanup_reason)
             | _ -> ())
           ~recovery
           ~allowed_root_path:directory
           ~parent
           ~leaf:"target"
           ~permissions:0o640
           "new"
         : (unit, Fs_compat.capability_write_error) result))
  in
  check bool (label ^ " preserves initial reason") true
    (observed_reason == reason);
  check_preserved_backtrace ~label backtrace observed_backtrace;
  check bool (label ^ " preserves operation") true
    (cancellation.operation = Fs_compat.Atomic_replace_operation);
  check bool (label ^ " preserves target effect") true
    (cancellation.target_effect = Fs_compat.Target_unchanged);
  check bool (label ^ " has no invented write primary") true
    (Option.is_none cancellation.interrupted_primary_failure);
  check bool (label ^ " has no invented recovery interruption") true
    (Option.is_none cancellation.interrupted_recovery);
  check_cancellation_cleanup_stages ~label
    ~expected_cleanup_stages:[ Fs_compat.Cleanup_unlink ] cancellation;
  check string "original cancellation retains old payload" "old"
    (read_file target);
  let stage = only_entry_except directory [ "target" ] in
  check string "cancelled cleanup retains staging payload" ""
    (read_file (Filename.concat (Filename.concat directory stage) "payload"))
;;

let test_cancelled_create_preserves_initial_cancellation_during_cleanup ~fs () =
  with_tmp_dir @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  let label = "cancelled create with cancelled cleanup" in
  let reason = Failure "initial create cancellation" in
  let backtrace = Printexc.get_callstack 32 in
  let observed_reason, cancellation, observed_backtrace =
    require_capability_write_cancellation ~label (fun () ->
      ignore
        (create_capability_file_for_testing ~recovery ~allowed_root_path:directory
           ~before_stage:(function
             | Fs_compat.Write_payload ->
               Printexc.raise_with_backtrace
                 (Eio.Cancel.Cancelled reason)
                 backtrace
             | Fs_compat.Cleanup_close ->
               raise (Eio.Cancel.Cancelled (Failure "later close cancellation"))
             | _ -> ())
           ~parent
           ~leaf:"target"
           ~permissions:0o640
           "new"
         : (unit, Fs_compat.capability_write_error) result))
  in
  check bool (label ^ " preserves initial reason") true
    (observed_reason == reason);
  check_preserved_backtrace ~label backtrace observed_backtrace;
  check bool (label ^ " preserves create operation") true
    (cancellation.operation = Fs_compat.Create_exclusive_operation);
  check bool (label ^ " preserves unmodified public target") true
    (cancellation.target_effect = Fs_compat.Target_unchanged);
  check bool (label ^ " has no invented write primary") true
    (Option.is_none cancellation.interrupted_primary_failure);
  check bool (label ^ " has no invented recovery interruption") true
    (Option.is_none cancellation.interrupted_recovery);
  check_cancellation_cleanup_stages ~label
    ~expected_cleanup_stages:[] cancellation;
  check bool "cancelled private creation never publishes a target" false
    (Sys.file_exists (Filename.concat directory "target"));
  let stage = only_entry_except directory [] in
  check string "interrupted cleanup preserves private payload evidence" ""
    (read_file (Filename.concat (Filename.concat directory stage) "payload"))
;;

let test_recovery_cancellation_preserves_authority_and_backtrace ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let reason = Failure "recovery discharge cancellation" in
  let backtrace = Printexc.get_callstack 32 in
  let observed_reason, cancellation, observed_backtrace =
    require_capability_write_cancellation
      ~label:"recovery discharge"
      (fun () ->
         ignore
           (replace_capability_file_for_testing
              ~before_stage:(function
                | Fs_compat.Discharge_bound_recovery_obligation ->
                  Printexc.raise_with_backtrace
                    (Eio.Cancel.Cancelled reason)
                    backtrace
                | _ -> ())
              ~recovery
              ~allowed_root_path:directory
              ~parent
              ~leaf:"target"
              ~permissions:0o640
              "new"
            : (unit, Fs_compat.capability_write_error) result))
  in
  check bool "recovery cancellation preserves reason identity" true
    (observed_reason == reason);
  check_preserved_backtrace ~label:"recovery cancellation"
    backtrace observed_backtrace;
  check bool "recovery cancellation preserves replacement effect" true
    (cancellation.target_effect = Fs_compat.Target_replaced);
  check bool "recovery cancellation has no write primary" true
    (Option.is_none cancellation.interrupted_primary_failure);
  check bool "recovery cancellation preserves operation" true
    (cancellation.operation = Fs_compat.Atomic_replace_operation);
  check bool "recovery cancellation has no invented cleanup failures" true
    (cancellation.cleanup_failures = []);
  check string "recovery cancellation retains published payload" "new"
    (read_file target);
  check (list string) "recovery cancellation has removed staging" [ "target" ]
    (directory_entries directory);
  (match cancellation.interrupted_recovery with
   | None -> fail "recovery cancellation omitted interruption authority"
   | Some interruption ->
     check bool "recovery cancellation preserves exact phase" true
       (Fs_compat.capability_recovery_failure_phase interruption
        = Fs_compat.Recovery_discharge_bound);
     check bool "pre-discharge cancellation records no record mutation" true
       (Fs_compat.capability_recovery_failure_effect interruption
        = Fs_compat.Recovery_no_record_change))
;;

let test_recovery_unlink_cancellation_retains_actual_effect ~fs ~write_primary () =
  let module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing in
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let record_names () = match Recovery_test.record_names recovery ~area:Recovery_test.Owned with
    | Ok names -> names
    | Error Recovery_test.Keeper_lane_not_available -> fail "recovery lane lost during inspection"
  in
  let reason = Failure "cancel after actual recovery record unlink" in
  let backtrace = Printexc.get_callstack 32 in
  let fault = match Recovery_test.discharge_cancellation
    ~owner:"capability-write-test" ~record:Recovery_test.Bound_record ~reason ~backtrace with
    | Ok fault -> fault
    | Error _ -> fail "valid recovery cancellation fixture owner was rejected"
  in
  let observed_record = ref false in
  let write_backtrace = Printexc.get_callstack 32 in
  let observed_reason, cancellation, observed_backtrace =
    require_capability_write_cancellation ~label:"after recovery unlink" (fun () ->
      Recovery_test.with_discharge_cancellation fault (fun () ->
        ignore (replace_capability_file_for_testing
          ~before_stage:(function
            | Fs_compat.Write_payload ->
              check int "real bound record exists before the attempted write" 1 (List.length (record_names ()));
              observed_record := true;
              if write_primary then Printexc.raise_with_backtrace Exit write_backtrace
            | _ -> ())
          ~recovery ~allowed_root_path:directory ~parent ~leaf:"target" ~permissions:0o640
          "new" : (unit, Fs_compat.capability_write_error) result)))
  in
  check bool "the write reached its durable bound obligation" true !observed_record;
  check bool "recovery unlink preserves original cancellation reason" true (observed_reason == reason);
  check_preserved_backtrace ~label:"after recovery unlink" backtrace observed_backtrace;
  check (list string) "actual owned record is gone after the injected cancellation" [] (record_names ());
  check bool "replacement operation preserved" true
    (cancellation.operation = Fs_compat.Atomic_replace_operation);
  check bool "target effect matches whether publication happened" true
    (cancellation.target_effect = if write_primary then Fs_compat.Target_unchanged else Fs_compat.Target_replaced);
  (match write_primary, cancellation.interrupted_primary_failure with
   | false, None -> ()
   | true, Some (Fs_compat.Write_primary_failure { stage = Fs_compat.Write_payload;
       cause = Fs_compat.Operation_failed { exception_; backtrace = primary_backtrace } }) ->
     check bool "original write failure survives recovery cleanup cancellation" true (exception_ == Exit);
     check_preserved_backtrace ~label:"write primary after recovery unlink"
       write_backtrace primary_backtrace
   | true, _ | false, Some _ -> fail "write primary authority changed during recovery cleanup");
  check bool "no invented cleanup failures" true (cancellation.cleanup_failures = []);
  check string "published target matches the actual write boundary"
    (if write_primary then "old" else "new") (read_file target);
  check (list string) "actual staging cleanup finished" [ "target" ] (directory_entries directory);
  match cancellation.interrupted_recovery with
  | None -> fail "actual recovery unlink interruption was lost"
  | Some interruption ->
    check bool "exact bound discharge phase survives" true
      (Fs_compat.capability_recovery_failure_phase interruption = Fs_compat.Recovery_discharge_bound);
    check bool "removed record is not reported as still durable" true
      (Fs_compat.capability_recovery_failure_effect interruption
       = Fs_compat.Recovery_source_removal_durability_unknown Fs_compat.Recovery_discharge_owned)
;;

let test_atomic_replace_preserves_requested_mode ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  Unix.chmod target 0o751;
  with_replace_context ~fs directory @@ fun parent recovery ->
  require_ok
    (replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o751
       "new");
  check string "payload replaced" "new" (read_file target);
  check int "requested mode retained" 0o751 ((Unix.stat target).st_perm land 0o777);
  check (list string) "only target remains" [ "target" ]
    (directory_entries directory)
;;

let test_atomic_replace_replaces_symlink_not_referent ~fs () =
  with_tmp_dir @@ fun directory ->
  let referent = Filename.concat directory "referent" in
  let target = Filename.concat directory "target" in
  write_file referent "referent";
  Unix.symlink "referent" target;
  with_replace_context ~fs directory @@ fun parent recovery ->
  require_ok
    (replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "replacement");
  check string "referent unchanged" "referent" (read_file referent);
  check string "leaf replaced" "replacement" (read_file target);
  check bool "leaf is now regular" true ((Unix.lstat target).st_kind = Unix.S_REG)
;;

let test_atomic_replace_writes_complete_large_payload ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let payload = String.init ((1024 * 1024) + 17) (fun index -> Char.chr (index mod 251)) in
  with_replace_context ~fs directory @@ fun parent recovery ->
  require_ok
    (replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       payload);
  check string "all bytes written" payload (read_file target)
;;

let test_atomic_replace_uses_typed_parent_components ~fs () =
  with_tmp_dir @@ fun directory ->
  let nested_directory = Filename.concat directory "nested" in
  let target_path = Filename.concat nested_directory "target" in
  Unix.mkdir nested_directory 0o700;
  write_file target_path "old";
  with_parent_capability ~fs directory @@ fun allowed_root ->
  let allowed_root_stat = Eio.Path.stat ~follow:true allowed_root in
  Eio.Path.with_open_dir Eio.Path.(allowed_root / "nested") @@ fun parent ->
  with_publication_recovery_access ~fs @@ fun recovery ->
  let target =
    match
      Fs_compat.capability_publication_target
        ~allowed_root_path:directory
        ~allowed_root_device:allowed_root_stat.dev
        ~allowed_root_inode:allowed_root_stat.ino
        ~parent_components:[ "nested" ]
        ~target_leaf:"target"
        ~permissions:0o640
    with
    | Ok target -> target
    | Error error ->
      fail (Fs_compat.capability_publication_target_error_to_string error)
  in
  require_ok
    (Fs_compat.replace_capability_file
       ~recovery
       ~parent
       ~target
       "new");
  check string "nested target replaced" "new" (read_file target_path)
;;

let test_atomic_replace_owns_restrictive_staging_directory ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  let observed_mode = ref None in
  with_replace_context ~fs directory @@ fun parent recovery ->
  require_ok
    (replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Create_staging_entry ->
           let staging = only_entry_except directory [ "target" ] in
           let stat = Unix.lstat (Filename.concat directory staging) in
           if stat.st_kind <> Unix.S_DIR
           then fail "staging entry is not a directory";
           observed_mode := Some (stat.st_perm land 0o777)
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "new");
  check (option int) "staging directory has exact restrictive mode" (Some 0o700)
    !observed_mode;
  check (list string) "owned staging directory removed" [ "target" ]
    (directory_entries directory)
;;

let test_replace_preflight_failure_keeps_known_target_state ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Publish_replace -> raise Exit
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "new"
   with
   | Ok () -> fail "fault-injected publish preflight unexpectedly succeeded"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "pre-rename failure stage retained" true
       (failure.stage = Fs_compat.Publish_replace);
     check bool "pre-rename target is known unchanged" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check string "old target retained" "old" (read_file target);
  check (list string) "failed publication cleaned staging" [ "target" ]
    (directory_entries directory)
;;

let test_replace_preflight_detects_payload_leaf_swap ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  let replacement_payload = ref None in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Verify_entry_identity ->
           let staging = only_entry_except directory [ "target" ] in
           let staging_path = Filename.concat directory staging in
           let payload = Filename.concat staging_path "payload" in
           Unix.rename payload (Filename.concat staging_path "original");
           write_file payload "replacement";
           replacement_payload := Some payload
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "new"
   with
   | Ok () -> fail "payload-leaf replacement was published"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "payload identity swap detected" true
       (failure.stage = Fs_compat.Verify_entry_identity);
     check bool "target remained known unchanged" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check string "old target retained after payload swap" "old" (read_file target);
  check bool "unknown replacement payload retained for inspection" true
    (Option.fold ~none:false ~some:Sys.file_exists !replacement_payload)
;;

let test_staging_name_swap_does_not_redirect_pinned_payload ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let displaced = Filename.concat directory "displaced" in
  write_file target "old";
  let replacement = ref None in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Publish_replace ->
           let staging = only_entry_except directory [ "target" ] in
           let staging_path = Filename.concat directory staging in
           Unix.rename staging_path displaced;
           Unix.mkdir staging_path 0o700;
           replacement := Some staging_path
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "new"
   with
   | Ok () -> fail "staging-name replacement was not observed"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "replacement detected before directory removal" true
       (failure.stage = Fs_compat.Verify_staging_directory_identity);
     check bool "payload still published from pinned capability" true
       (error.target_effect = Fs_compat.Target_replaced));
  check string "pinned payload reached target" "new" (read_file target);
  check bool "replacement directory was not unsafely removed" true
    (Option.fold ~none:false ~some:Sys.is_directory !replacement);
  check bool "displaced pinned directory remains observable" true
    (Sys.is_directory displaced)
;;

let test_append_and_replace_share_existing_target_lease ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let target_alias = Filename.concat directory "target-alias" in
  write_file target "old";
  Unix.link target target_alias;
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let writer_entered, resolve_writer_entered = Eio.Promise.create () in
  let release_writer, resolve_release_writer = Eio.Promise.create () in
  let writer_result, resolve_writer_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      replace_capability_file_for_testing
        ~before_stage:(function
          | Fs_compat.Create_staging_directory ->
            Eio.Promise.resolve resolve_writer_entered ();
            Eio.Promise.await release_writer
          | _ -> ())
        ~recovery
        ~allowed_root_path:directory
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "replacement"
    in
    Eio.Promise.resolve resolve_writer_result result);
  Eio.Promise.await writer_entered;
  let append_outcome, alias_rejected =
    Eio.Switch.run @@ fun append_sw ->
    let file =
      Fs_compat.open_capability_append_file
        ~sw:append_sw
        ~parent
        ~leaf:"target-alias"
      |> require_append_file
    in
    let alias_rejected =
      match
        Fs_compat.open_capability_append_file
          ~sw:append_sw
          ~parent
          ~leaf:"./target"
      with
      | Error (Fs_compat.Capability_append_open_invalid_leaf "./target") -> true
      | Error _ | Ok _ -> false
    in
    Fs_compat.append_capability_observed file "append", alias_rejected
  in
  check bool "hard-link alias reports target identity contention" true
    (append_outcome.write_failure
     = Some Fs_compat.Capability_append_mutation_contended);
  check int "contended append writes no bytes" 0 append_outcome.bytes_written;
  check bool "alternate spelling is rejected before lease lookup" true
    alias_rejected;
  check string "target stays old while replacement is paused" "old"
    (read_file target);
  Eio.Promise.resolve resolve_release_writer ();
  (match Eio.Promise.await writer_result with
   | Ok () -> ()
   | Error error -> fail (Fs_compat.capability_write_error_to_string error));
  let append_after_release =
    Eio.Switch.run @@ fun append_sw ->
    let file =
      Fs_compat.open_capability_append_file
        ~sw:append_sw
        ~parent
        ~leaf:"target"
      |> require_append_file
    in
    Fs_compat.append_capability_observed file "after-release"
  in
  check bool "atomic writer releases the target identity lease" true
    (Option.is_none append_after_release.write_failure);
  check string "replacement completes before the later append"
    "replacementafter-release"
    (read_file target)
;;

let test_hard_link_replaces_share_existing_target_lease ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let target_alias = Filename.concat directory "target-alias" in
  write_file target "old";
  Unix.link target target_alias;
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let writer_entered, resolve_writer_entered = Eio.Promise.create () in
  let release_writer, resolve_release_writer = Eio.Promise.create () in
  let writer_result, resolve_writer_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      replace_capability_file_for_testing
        ~before_stage:(function
          | Fs_compat.Create_staging_directory ->
            Eio.Promise.resolve resolve_writer_entered ();
            Eio.Promise.await release_writer
          | _ -> ())
        ~recovery
        ~allowed_root_path:directory
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "replacement"
    in
    Eio.Promise.resolve resolve_writer_result result);
  Eio.Promise.await writer_entered;
  (match
     replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target-alias"
       ~permissions:0o640
       "alias-replacement"
   with
   | Ok () -> fail "hard-link alias bypassed the existing-target lease"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "hard-link replace reports target identity contention" true
       (failure.stage = Fs_compat.Acquire_mutation_lease
        && failure.cause = Fs_compat.Mutation_contended));
  check string "both names retain the old inode while paused" "old"
    (read_file target_alias);
  Eio.Promise.resolve resolve_release_writer ();
  Eio.Promise.await writer_result |> require_ok;
  require_ok
    (replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target-alias"
       ~permissions:0o640
       "alias-replacement");
  check string "first replace publishes its payload" "replacement"
    (read_file target);
  check string "released inode lease permits the alias replace"
    "alias-replacement"
    (read_file target_alias)
;;

let test_replace_reobserves_binding_after_lease_acquisition ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let displaced = Filename.concat directory "displaced" in
  write_file target "old";
  let swapped = ref false in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Acquire_mutation_lease when not !swapped ->
           swapped := true;
           Unix.rename target displaced;
           write_file target "external-replacement"
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "writer-payload"
   with
   | Ok () -> fail "replace accepted a binding changed before lease acquisition"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "binding drift is explicit after lease acquisition" true
       (failure.stage = Fs_compat.Inspect_target_entry
        && failure.cause = Fs_compat.Resource_identity_changed);
     check bool "writer reports no target mutation" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check bool "test changed the binding at the acquisition boundary" true !swapped;
  check string "new binding remains untouched" "external-replacement"
    (read_file target);
  check string "displaced preliminary inode remains untouched" "old"
    (read_file displaced);
  check (list string) "no staging state was created before binding validation"
    [ "displaced"; "target" ]
    (directory_entries directory);
  require_ok
    (replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "after-release");
  check string "failed validation released its preliminary inode lease"
    "after-release"
    (read_file target)
;;

let test_existing_replace_reobserves_binding_at_publication ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  let unlinked = ref false in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Acquire_publication_lease when not !unlinked ->
           unlinked := true;
           Unix.unlink target
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "writer-payload"
   with
   | Ok () -> fail "existing replace republished over an externally unlinked target"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "final target reobservation reports exact binding drift" true
       (failure.stage = Fs_compat.Verify_target_binding
        && failure.cause = Fs_compat.Resource_identity_changed);
     check bool "failed final validation reports no publication" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check bool "test removed the target before the publication guard" true
    !unlinked;
  check bool "old replace did not recreate the unlinked name" false
    (Sys.file_exists target);
  check (list string) "failed publication cleaned its staging state" []
    (directory_entries directory);
  require_ok
    (create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "after-release");
  check string "publication guard releases after final validation failure"
    "after-release"
    (read_file target)
;;

let test_existing_replace_yields_to_cooperative_absent_publication ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let stale_at_guard, resolve_stale_at_guard = Eio.Promise.create () in
  let release_stale_guard, resolve_release_stale_guard = Eio.Promise.create () in
  let stale_result, resolve_stale_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      replace_capability_file_for_testing
        ~before_stage:(function
          | Fs_compat.Acquire_publication_lease ->
            Eio.Promise.resolve resolve_stale_at_guard ();
            Eio.Promise.await release_stale_guard
          | _ -> ())
        ~recovery
        ~allowed_root_path:directory
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "stale-replacement"
    in
    Eio.Promise.resolve resolve_stale_result result);
  Eio.Promise.await stale_at_guard;
  Unix.unlink target;
  let create_visible, resolve_create_visible = Eio.Promise.create () in
  let release_create, resolve_release_create = Eio.Promise.create () in
  let create_result, resolve_create_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      create_capability_file_for_testing ~recovery ~allowed_root_path:directory
        ~before_stage:(function
          | Fs_compat.Inspect_open_resource ->
            Eio.Promise.resolve resolve_create_visible ();
            Eio.Promise.await release_create
          | _ -> ())
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "cooperative-publication"
    in
    Eio.Promise.resolve resolve_create_result result);
  Eio.Promise.await create_visible;
  Eio.Promise.resolve resolve_release_stale_guard ();
  (match Eio.Promise.await stale_result with
   | Ok () -> fail "stale replace crossed a cooperative absent publication"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "stale replace reports short publication contention" true
       (failure.stage = Fs_compat.Acquire_publication_lease
        && failure.cause = Fs_compat.Mutation_contended);
     check bool "stale replace reports no target effect" true
       (error.target_effect = Fs_compat.Target_unchanged));
  Eio.Promise.resolve resolve_release_create ();
  Eio.Promise.await create_result |> require_ok;
  check string "cooperative absent writer retains the public target"
    "cooperative-publication"
    (read_file target);
  check (list string) "stale writer cleaned its private staging state"
    [ "target" ]
    (directory_entries directory)
;;

let test_absent_replace_reobserves_binding_at_publication ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let inserted = ref false in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Verify_target_binding when not !inserted ->
           inserted := true;
           write_file target "external"
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "writer-payload"
   with
   | Ok () -> fail "absent replace overwrote a target inserted before publication"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "absent publication reobserves the exact target binding" true
       (failure.stage = Fs_compat.Verify_target_binding
        && failure.cause = Fs_compat.Resource_identity_changed);
     check bool "inserted target remains outside writer effects" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check bool "test inserted the target at final observation" true !inserted;
  check string "external target is not overwritten" "external"
    (read_file target);
  check (list string) "failed absent publication cleans staging" [ "target" ]
    (directory_entries directory)
;;

let test_existing_publication_guard_blocks_absent_sibling ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let sibling = Filename.concat directory "sibling" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let guard_held, resolve_guard_held = Eio.Promise.create () in
  let release_guard, resolve_release_guard = Eio.Promise.create () in
  let writer_result, resolve_writer_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      replace_capability_file_for_testing
        ~before_stage:(function
          | Fs_compat.Verify_target_binding ->
            Eio.Promise.resolve resolve_guard_held ();
            Eio.Promise.await release_guard
          | _ -> ())
        ~recovery
        ~allowed_root_path:directory
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "replacement"
    in
    Eio.Promise.resolve resolve_writer_result result);
  Eio.Promise.await guard_held;
  (match
     create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"sibling"
       ~permissions:0o640
       "sibling"
   with
   | Ok () -> fail "absent sibling crossed an active publication guard"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "short publication guard reports parent contention" true
       (failure.stage = Fs_compat.Acquire_mutation_lease
        && failure.cause = Fs_compat.Mutation_contended));
  check bool "contended sibling remains absent" false
    (Sys.file_exists sibling);
  Eio.Promise.resolve resolve_release_guard ();
  Eio.Promise.await writer_result |> require_ok;
  require_ok
    (create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"sibling"
       ~permissions:0o640
       "sibling");
  check string "publication completed after releasing the guard" "replacement"
    (read_file target);
  check string "absent sibling proceeds after the short guard" "sibling"
    (read_file sibling)
;;

let test_absent_replace_blocks_visible_and_absent_sibling_mutations ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let sibling = Filename.concat directory "sibling" in
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let published, resolve_published = Eio.Promise.create () in
  let release_writer, resolve_release_writer = Eio.Promise.create () in
  let writer_result, resolve_writer_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      replace_capability_file_for_testing
        ~before_stage:(function
          | Fs_compat.Sync_staging_directory ->
            Eio.Promise.resolve resolve_published ();
            Eio.Promise.await release_writer
          | _ -> ())
        ~recovery
        ~allowed_root_path:directory
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "replacement"
    in
    Eio.Promise.resolve resolve_writer_result result);
  Eio.Promise.await published;
  check string "absent replace has published before the pause" "replacement"
    (read_file target);
  let append_outcome =
    Eio.Switch.run @@ fun append_sw ->
    let file =
      Fs_compat.open_capability_append_file
        ~sw:append_sw
        ~parent
        ~leaf:"target"
      |> require_append_file
    in
    Fs_compat.append_capability_observed file "append"
  in
  check bool "published inode remains covered by the absent-parent lease" true
    (append_outcome.write_failure
     = Some Fs_compat.Capability_append_mutation_contended);
  (match
     replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "contending-replace"
   with
   | Ok () -> fail "published absent replace admitted an existing-target replace"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "published target replace reports parent transition contention"
       true
       (failure.stage = Fs_compat.Acquire_mutation_lease
        && failure.cause = Fs_compat.Mutation_contended));
  (match
     create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"sibling"
       ~permissions:0o640
       "sibling"
   with
   | Ok () -> fail "absent sibling bypassed the absent-parent lease"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "absent sibling reports the same parent contention" true
       (failure.stage = Fs_compat.Acquire_mutation_lease
        && failure.cause = Fs_compat.Mutation_contended));
  check bool "contended absent sibling was not created" false
    (Sys.file_exists sibling);
  Eio.Promise.resolve resolve_release_writer ();
  Eio.Promise.await writer_result |> require_ok;
  require_ok
    (create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"sibling"
       ~permissions:0o640
       "sibling");
  check string "absent-parent lease releases after replace completion" "sibling"
    (read_file sibling)
;;

let test_exclusive_create_remains_private_under_parent_lease ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let target_visible, resolve_target_visible = Eio.Promise.create () in
  let release_create, resolve_release_create = Eio.Promise.create () in
  let create_result, resolve_create_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      create_capability_file_for_testing ~recovery ~allowed_root_path:directory
        ~before_stage:(function
          | Fs_compat.Inspect_open_resource ->
            Eio.Promise.resolve resolve_target_visible ();
            Eio.Promise.await release_create
          | _ -> ())
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "created"
    in
    Eio.Promise.resolve resolve_create_result result);
  Eio.Promise.await target_visible;
  check bool "exclusive target remains private before publication" false
    (Sys.file_exists target);
  Eio.Switch.run (fun append_sw ->
    match Fs_compat.open_capability_append_file ~sw:append_sw ~parent ~leaf:"target" with
    | Error Fs_compat.Capability_append_open_missing -> ()
    | Ok _ -> fail "append opened a private in-progress create"
    | Error (Fs_compat.Capability_append_open_invalid_leaf _
            | Fs_compat.Capability_append_open_failed _) -> fail "unexpected append lookup failure");
  (match
     replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "replacement"
   with
   | Ok () -> fail "replace entered a visible incomplete exclusive create"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "replace reports the create transition contention" true
       (failure.stage = Fs_compat.Acquire_mutation_lease
        && failure.cause = Fs_compat.Mutation_contended));
  Eio.Promise.resolve resolve_release_create ();
  Eio.Promise.await create_result |> require_ok;
  check string "exclusive creator completes without interleaved mutation"
    "created"
    (read_file target)
;;

let test_existing_target_lease_allows_absent_sibling_progress ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let sibling = Filename.concat directory "sibling" in
  let replacement_sibling = Filename.concat directory "replacement-sibling" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let writer_entered, resolve_writer_entered = Eio.Promise.create () in
  let release_writer, resolve_release_writer = Eio.Promise.create () in
  let writer_result, resolve_writer_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      replace_capability_file_for_testing
        ~before_stage:(function
          | Fs_compat.Create_staging_directory ->
            Eio.Promise.resolve resolve_writer_entered ();
            Eio.Promise.await release_writer
          | _ -> ())
        ~recovery
        ~allowed_root_path:directory
        ~parent
        ~leaf:"target"
        ~permissions:0o640
        "replacement"
    in
    Eio.Promise.resolve resolve_writer_result result);
  Eio.Promise.await writer_entered;
  require_ok
    (create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"sibling"
       ~permissions:0o640
       "sibling");
  require_ok
    (replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"replacement-sibling"
       ~permissions:0o640
       "replacement-sibling");
  check string "exclusive create progresses beside existing target mutation"
    "sibling"
    (read_file sibling);
  check string "absent replace progresses beside existing target mutation"
    "replacement-sibling"
    (read_file replacement_sibling);
  check string "paused existing target remains unchanged" "old"
    (read_file target);
  Eio.Promise.resolve resolve_release_writer ();
  Eio.Promise.await writer_result |> require_ok;
  check string "existing target completes after sibling publications"
    "replacement"
    (read_file target)
;;

let test_append_lease_blocks_replace_then_releases ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let file =
    Fs_compat.open_capability_append_file ~sw ~parent ~leaf:"target"
    |> require_append_file
  in
  let append_entered, resolve_append_entered = Eio.Promise.create () in
  let release_append, resolve_release_append = Eio.Promise.create () in
  let append_result, resolve_append_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let outcome =
      Fs_compat.Capability_append_for_testing.append_capability_observed
        ~after_write:(fun () ->
          Eio.Promise.resolve resolve_append_entered ();
          Eio.Promise.await release_append)
        file
        "-append"
    in
    Eio.Promise.resolve resolve_append_result outcome);
  Eio.Promise.await append_entered;
  (match
     replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "replacement"
   with
   | Ok () -> fail "replace bypassed the append entry lease"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "replace reports immediate entry contention" true
       (failure.stage = Fs_compat.Acquire_mutation_lease
        && failure.cause = Fs_compat.Mutation_contended));
  check string "append bytes remain visible while its lease is held"
    "old-append"
    (read_file target);
  Eio.Promise.resolve resolve_release_append ();
  let append_outcome = Eio.Promise.await append_result in
  check bool "append completes on the pinned target" true
    (append_outcome.target_binding = Fs_compat.Capability_append_target_verified);
  require_ok
    (replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "replacement");
  check string "replace succeeds after append releases the lease"
    "replacement"
    (read_file target)
;;

let test_independent_targets_progress_without_global_io_serialization ~fs () =
  with_tmp_dir @@ fun directory ->
  let target_a = Filename.concat directory "target-a" in
  let target_b = Filename.concat directory "target-b" in
  write_file target_a "old-a";
  write_file target_b "old-b";
  with_replace_context ~fs directory @@ fun parent recovery ->
  Eio.Switch.run @@ fun sw ->
  let writer_a_entered, resolve_writer_a_entered = Eio.Promise.create () in
  let release_writer_a, resolve_release_writer_a = Eio.Promise.create () in
  let writer_a_result, resolve_writer_a_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      replace_capability_file_for_testing
        ~before_stage:(function
          | Fs_compat.Create_staging_directory ->
            Eio.Promise.resolve resolve_writer_a_entered ();
            Eio.Promise.await release_writer_a
          | _ -> ())
        ~recovery
        ~allowed_root_path:directory
        ~parent
        ~leaf:"target-a"
        ~permissions:0o640
        "new-a"
    in
    Eio.Promise.resolve resolve_writer_a_result result);
  Eio.Promise.await writer_a_entered;
  let writer_b_result =
    replace_capability_file
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target-b"
       ~permissions:0o640
       "new-b"
  in
  let target_b_while_a_paused = read_file target_b in
  check string "paused target remains unchanged" "old-a" (read_file target_a);
  Eio.Promise.resolve resolve_release_writer_a ();
  let writer_a_result = Eio.Promise.await writer_a_result in
  require_ok writer_b_result;
  require_ok writer_a_result;
  check string "independent target completes while target A is paused"
    "new-b"
    target_b_while_a_paused;
  check string "paused target completes after release" "new-a"
    (read_file target_a)
;;

let test_create_exclusive_does_not_overwrite ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "existing";
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o644
       "new"
   with
   | Ok () -> fail "exclusive create overwrote an existing entry"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "failure is create stage" true
       (failure.stage = Fs_compat.Inspect_target_entry);
     check bool "target is known unchanged" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check string "existing payload retained" "existing" (read_file target)
;;

let test_create_exclusive_refuses_postcheck_intruder ~fs () =
  let module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing in
  List.iter
    (fun kind -> with_tmp_dir @@ fun directory ->
       let target = Filename.concat directory "target" in
       let sentinel = Filename.concat directory "foreign" in
       write_file sentinel "foreign bytes";
       let planted = ref None in
       with_replace_context ~fs directory @@ fun parent recovery ->
       (match create_capability_file_for_testing ~recovery ~allowed_root_path:directory
          ~before_stage:(function
            | Fs_compat.Publish_exclusive ->
              (match kind with
               | `Regular -> write_file target "foreign bytes"
               | `Symlink -> Unix.symlink sentinel target
               | `Hardlink -> Unix.link sentinel target);
              planted := Some (Unix.lstat target)
            | _ -> ())
          ~parent ~leaf:"target" ~permissions:0o640 "our new payload" with
        | Ok () -> fail "post-check foreign target was overwritten"
        | Error error ->
          let failure = require_write_primary_failure error in
          check bool "real no-replace publication refused" true
            (failure.stage = Fs_compat.Publish_exclusive);
          (match failure.cause with
           | Fs_compat.Operation_failed
               { exception_ = Unix.Unix_error (Unix.EEXIST, _, _); _ } -> ()
           | _ -> fail "did not exercise the actual no-replace syscall");
          check bool "EEXIST has a known unchanged target effect" true
            (error.target_effect = Fs_compat.Target_unchanged);
          check int "normal cleanup has no failed effects" 0 (List.length error.cleanup_failures));
       let before = match !planted with Some stat -> stat | None -> fail "publish hook not reached" in
       let after = Unix.lstat target in
       check int "foreign inode preserved" before.st_ino after.st_ino;
       check int "foreign device preserved" before.st_dev after.st_dev;
       check string "foreign bytes preserved" "foreign bytes" (read_file target);
       check string "sentinel untouched" "foreign bytes" (read_file sentinel);
       check (list string) "only foreign target and sentinel remain" ["foreign"; "target"]
         (directory_entries directory);
       List.iter (fun area ->
         match Recovery_test.record_names recovery ~area with
         | Ok names -> check (list string) "exact operation was discharged" [] names
         | Error Recovery_test.Keeper_lane_not_available -> fail "original recovery lane lost")
         [Recovery_test.Active; Recovery_test.Owned; Recovery_test.Forensic];
       require_ok (create_capability_file ~recovery ~allowed_root_path:directory
         ~parent ~leaf:"next-target" ~permissions:0o640 "same lane continues");
       check string "same lane can publish a different leaf" "same lane continues"
         (read_file (Filename.concat directory "next-target")))
    [`Regular; `Symlink; `Hardlink]
;;

let test_create_exclusive_success ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_replace_context ~fs directory @@ fun parent recovery ->
  require_ok
    (create_capability_file ~recovery ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "created");
  check string "payload created" "created" (read_file target);
  check int "requested mode applied" 0o640 ((Unix.stat target).st_perm land 0o777)
;;

let test_create_failure_preserves_private_boundary ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     create_capability_file_for_testing ~recovery ~allowed_root_path:directory
       ~before_stage:(function
         | Fs_compat.Apply_permissions -> raise Exit
         | _ -> ())
       ~parent
       ~leaf:"target"
       ~permissions:0o644
       "partial"
   with
   | Ok () -> fail "fault-injected exclusive create unexpectedly succeeded"
   | Error error ->
     check bool "public target is known unchanged" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check bool "private write failure never creates a public leaf" false (Sys.file_exists target);
  check (list string) "owned private staging was removed" [] (directory_entries directory)
;;

let test_create_parent_sync_failure_preserves_complete_effect ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     create_capability_file_for_testing ~recovery ~allowed_root_path:directory
       ~before_stage:(function
         | Fs_compat.Sync_parent -> raise Exit
         | _ -> ())
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "complete"
   with
   | Ok () -> fail "fault-injected parent sync unexpectedly succeeded"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "failure remains parent sync" true
       (failure.stage = Fs_compat.Sync_parent);
     check bool "lexical target is complete" true
       (error.target_effect = Fs_compat.Target_created));
  check string "complete payload is inspectable" "complete" (read_file target);
  check int "requested mode was applied" 0o640
    ((Unix.stat target).st_perm land 0o777)
;;

let test_parent_fsync_failure_is_not_success ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Sync_parent -> raise Exit
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o644
       "new"
   with
   | Ok () -> fail "parent fsync failure was downgraded to success"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "exact failure stage" true
       (failure.stage = Fs_compat.Sync_parent);
     check bool "rename effect retained" true
       (error.target_effect = Fs_compat.Target_replaced));
  check string "rename completed before fsync failure" "new" (read_file target)
;;

let test_primary_and_cleanup_failures_are_preserved ~fs () =
  with_tmp_dir @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Write_payload | Fs_compat.Cleanup_unlink -> raise Exit
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o644
       "payload"
   with
   | Ok () -> fail "fault-injected write unexpectedly succeeded"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "primary write stage retained" true
       (failure.stage = Fs_compat.Write_payload);
     check bool "cleanup failure retained" true
       (has_write_cleanup_stage Fs_compat.Cleanup_unlink error));
  let entries = directory_entries directory in
  check int "fault injection left one observable staging directory" 1
    (List.length entries);
  check bool "observable staging entry is a directory" true
    (Sys.is_directory (Filename.concat directory (List.hd entries)))
;;

let test_replace_primary_failure_survives_cleanup_cancellation ~fs () =
  with_tmp_dir @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (replace_capability_file_for_testing
             ~before_stage:(function
               | Fs_compat.Write_payload -> raise Exit
               | Fs_compat.Cleanup_close ->
                 Eio.Cancel.cancel context Exit;
                 Eio.Fiber.check ()
               | _ -> ())
             ~recovery
             ~allowed_root_path:directory
             ~parent
             ~leaf:"target"
             ~permissions:0o644
             "payload"
           : (unit, Fs_compat.capability_write_error) result));
      None
    with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (_, cancellation)) ->
      Some cancellation
    | Eio.Cancel.Cancelled _ ->
      fail "replace cleanup cancellation lost the interrupted write failure"
  in
  match cancellation with
  | None -> fail "replace cleanup cancellation was swallowed"
  | Some cancellation ->
    (match cancellation.interrupted_primary_failure with
     | Some (Fs_compat.Write_primary_failure failure) ->
       check bool "replace interrupted primary stage" true
         (failure.stage = Fs_compat.Write_payload)
     | Some (Fs_compat.Recovery_primary_failure failure) ->
       fail (Fs_compat.capability_recovery_failure_to_string failure)
     | Some (Fs_compat.Recovery_access_primary_failure _) ->
       fail "replace reported recovery access as the interrupted primary"
     | None -> fail "replace omitted the interrupted write failure")
;;

let test_create_primary_failure_survives_cleanup_cancellation ~fs () =
  with_tmp_dir @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (create_capability_file_for_testing ~recovery ~allowed_root_path:directory
             ~before_stage:(function
               | Fs_compat.Write_payload -> raise Exit
               | Fs_compat.Cleanup_close ->
                 Eio.Cancel.cancel context Exit;
                 Eio.Fiber.check ()
               | _ -> ())
             ~parent
             ~leaf:"target"
             ~permissions:0o644
             "payload"
           : (unit, Fs_compat.capability_write_error) result));
      None
    with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (_, cancellation)) ->
      Some cancellation
    | Eio.Cancel.Cancelled _ ->
      fail "create cleanup cancellation lost the interrupted write failure"
  in
  match cancellation with
  | None -> fail "create cleanup cancellation was swallowed"
  | Some cancellation ->
    (match cancellation.interrupted_primary_failure with
     | Some (Fs_compat.Write_primary_failure failure) ->
       check bool "create interrupted primary stage" true
         (failure.stage = Fs_compat.Write_payload)
     | Some (Fs_compat.Recovery_primary_failure failure) ->
       fail (Fs_compat.capability_recovery_failure_to_string failure)
     | Some (Fs_compat.Recovery_access_primary_failure _) ->
       fail "create reported recovery access as the interrupted primary"
     | None -> fail "create omitted the interrupted write failure")
;;

let test_precommit_cancellation_cleans_staging ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancelled =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (replace_capability_file_for_testing
             ~before_stage:(function
               | Fs_compat.Write_payload ->
                 Eio.Cancel.cancel context Exit;
                 Eio.Fiber.check ()
               | _ -> ())
             ~recovery
             ~allowed_root_path:directory
             ~parent
             ~leaf:"target"
             ~permissions:0o644
             "new"
           : (unit, Fs_compat.capability_write_error) result));
      false
    with
    | Eio.Cancel.Cancelled _ -> true
  in
  check bool "cancellation propagated" true cancelled;
  check string "target unchanged" "old" (read_file target);
  check (list string) "staging cleaned" [ "target" ]
    (directory_entries directory)
;;

let test_pending_payload_sync_cancellation_does_not_publish ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancelled =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (replace_capability_file_for_testing
             ~before_stage:(function
               | Fs_compat.Close_payload -> Eio.Cancel.cancel context Exit
               | _ -> ())
             ~recovery
             ~allowed_root_path:directory
             ~parent
             ~leaf:"target"
             ~permissions:0o644
             "new"
           : (unit, Fs_compat.capability_write_error) result));
      false
    with
    | Eio.Cancel.Cancelled _ -> true
  in
  check bool "pending sync cancellation propagated" true cancelled;
  check string "pending cancellation did not publish" "old" (read_file target);
  check (list string) "cancelled sync cleaned staging" [ "target" ]
    (directory_entries directory)
;;

let test_cleanup_identity_failure_never_unlinks_unknown_payload ~fs () =
  with_tmp_dir @@ fun directory ->
  let swapped_payload = ref None in
  with_replace_context ~fs directory @@ fun parent recovery ->
  (match
     replace_capability_file_for_testing
       ~before_stage:(function
         | Fs_compat.Write_payload -> raise Exit
         | Fs_compat.Cleanup_verify_identity ->
           let staging = only_entry_except directory [] in
           let staging_path = Filename.concat directory staging in
           let payload = Filename.concat staging_path "payload" in
           Unix.rename payload (Filename.concat staging_path "original");
           write_file payload "replacement";
           swapped_payload := Some payload
         | _ -> ())
       ~recovery
       ~allowed_root_path:directory
       ~parent
       ~leaf:"target"
       ~permissions:0o644
       "new"
   with
   | Ok () -> fail "fault-injected write unexpectedly succeeded"
   | Error error ->
     check bool "identity drift retained as cleanup failure" true
       (List.exists
          (function
            | Fs_compat.Write_cleanup_failure failure ->
              failure.stage = Fs_compat.Cleanup_verify_identity
              && failure.cause = Fs_compat.Resource_identity_changed
            | Fs_compat.Recovery_cleanup_failure _ -> false)
          error.cleanup_failures);
     check bool "unknown payload was not unlinked" true
       (Option.fold ~none:false ~some:Sys.file_exists !swapped_payload));
  check bool "public target was never created" false
    (Sys.file_exists (Filename.concat directory "target"))
;;

let test_exclusive_create_cancellation_keeps_public_leaf_absent ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancelled =
    try
      Eio.Cancel.sub (fun context ->
        ignore (create_capability_file_for_testing ~recovery ~allowed_root_path:directory
          ~before_stage:(function
            | Fs_compat.Apply_permissions -> Eio.Cancel.cancel context Exit; Eio.Fiber.check ()
            | _ -> ())
          ~parent ~leaf:"target" ~permissions:0o644 "private payload"));
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "original cancellation propagated" true cancelled;
  check bool "cancelled private payload is never public" false (Sys.file_exists target);
  check (list string) "cancelled private staging was cleaned" [] (directory_entries directory)
;;

let test_commit_cancellation_finishes_durable_replace ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (replace_capability_file_for_testing
             ~before_stage:(function
               | Fs_compat.Publish_replace -> Eio.Cancel.cancel context Exit
               | _ -> ())
             ~recovery
             ~allowed_root_path:directory
             ~parent
             ~leaf:"target"
             ~permissions:0o644
             "new"
           : (unit, Fs_compat.capability_write_error) result));
      None
    with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (_, cancellation)) ->
      Some cancellation
    | Eio.Cancel.Cancelled _ -> fail "typed replace commit state was lost"
  in
  check (option bool) "replace effect retained after cancellation" (Some true)
    (Option.map
       (fun (cancellation : Fs_compat.capability_write_cancellation) ->
          cancellation.target_effect = Fs_compat.Target_replaced)
       cancellation);
  check (option bool) "replace operation retained" (Some true)
    (Option.map
       (fun (cancellation : Fs_compat.capability_write_cancellation) ->
          cancellation.operation = Fs_compat.Atomic_replace_operation)
       cancellation);
  check (option bool) "no write primary was interrupted" (Some true)
    (Option.map
       (fun (cancellation : Fs_compat.capability_write_cancellation) ->
          Option.is_none cancellation.interrupted_primary_failure)
       cancellation);
  check string "protected replace completed" "new" (read_file target);
  check (list string) "no staging orphan" [ "target" ]
    (directory_entries directory)
;;

let test_create_commit_cancellation_reports_complete_effect ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (create_capability_file_for_testing ~recovery ~allowed_root_path:directory
             ~before_stage:(function
               | Fs_compat.Sync_parent -> Eio.Cancel.cancel context Exit
               | _ -> ())
             ~parent
             ~leaf:"target"
             ~permissions:0o640
             "complete"
           : (unit, Fs_compat.capability_write_error) result));
      None
    with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (_, cancellation)) ->
      Some cancellation
    | Eio.Cancel.Cancelled _ -> fail "typed create commit state was lost"
  in
  check (option bool) "complete creation effect observed" (Some true)
    (Option.map
       (fun (cancellation : Fs_compat.capability_write_cancellation) ->
          cancellation.target_effect = Fs_compat.Target_created)
       cancellation);
  check (option bool) "create operation retained" (Some true)
    (Option.map
       (fun (cancellation : Fs_compat.capability_write_cancellation) ->
          cancellation.operation = Fs_compat.Create_exclusive_operation)
       cancellation);
  check (option bool) "no primary failure was interrupted" (Some true)
    (Option.map
       (fun (cancellation : Fs_compat.capability_write_cancellation) ->
          Option.is_none cancellation.interrupted_primary_failure)
       cancellation);
  check string "protected create completed" "complete" (read_file target)
;;

let test_split_writes_reject_non_leaf_path ~fs () =
  with_tmp_dir @@ fun directory ->
  with_parent_capability ~fs directory @@ fun parent ->
  let root = Eio.Path.stat ~follow:true parent in
  let sibling = "escape-" ^ Filename.basename directory in
  let invalid_leaves =
    [ ""; "."; ".."; "nested/leaf"; "../" ^ sibling; Filename.concat directory "absolute" ]
  in
  List.iter
    (fun leaf ->
      (match
         Fs_compat.capability_publication_target
           ~allowed_root_path:directory
           ~allowed_root_device:root.dev
           ~allowed_root_inode:root.ino
           ~parent_components:[]
           ~target_leaf:leaf
           ~permissions:0o644
       with
       | Ok _ -> failf "replace projection accepted non-leaf path: %S" leaf
       | Error _ -> ()))
    invalid_leaves;
  check bool "unique outside entry absent" false
    (Sys.file_exists (Filename.concat (Filename.dirname directory) sibling))
;;

let test_replace_rejects_directory_and_fifo_targets ~fs () =
  with_tmp_dir @@ fun directory ->
  let directory_target = Filename.concat directory "directory-target" in
  let fifo_target = Filename.concat directory "fifo-target" in
  Unix.mkdir directory_target 0o700;
  Unix.mkfifo fifo_target 0o600;
  with_replace_context ~fs directory @@ fun parent recovery ->
  List.iter
    (fun (leaf, expected_kind) ->
      match
        replace_capability_file
          ~recovery
          ~allowed_root_path:directory
          ~parent
          ~leaf
          ~permissions:0o640
          "replacement"
      with
      | Ok () -> failf "replace accepted unsupported target kind: %s" leaf
      | Error error ->
        let failure = require_write_primary_failure error in
        check bool (leaf ^ " rejected during target inspection") true
          (failure.stage = Fs_compat.Inspect_target_entry);
        check bool (leaf ^ " retains exact target kind") true
          (failure.cause = Fs_compat.Unexpected_resource_kind expected_kind);
        check bool (leaf ^ " remains unchanged") true
          (error.target_effect = Fs_compat.Target_unchanged))
    [ "directory-target", `Directory; "fifo-target", `Fifo ];
  check bool "directory target remains a directory" true
    (Sys.is_directory directory_target);
  check bool "fifo target remains a fifo" true
    ((Unix.lstat fifo_target).st_kind = Unix.S_FIFO)
;;

let test_recovery_transition_cancellation_is_typed ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (replace_capability_file_for_testing
             ~before_stage:(function
               | Fs_compat.Prepare_recovery_obligation ->
                 Eio.Cancel.cancel context Exit;
                 Eio.Fiber.check ()
               | _ -> ())
             ~recovery
             ~allowed_root_path:directory
             ~parent
             ~leaf:"target"
             ~permissions:0o640
             "new"
           : (unit, Fs_compat.capability_write_error) result));
      fail "recovery transition cancellation was swallowed"
    with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (_, cancellation)) ->
      cancellation
    | Eio.Cancel.Cancelled _ ->
      fail "recovery transition cancellation lost its typed state"
  in
  check bool "replace operation retained" true
    (cancellation.operation = Fs_compat.Atomic_replace_operation);
  (match cancellation.interrupted_recovery with
   | None -> fail "recovery transition interruption was omitted"
   | Some interruption ->
     check bool "exact recovery phase retained" true
       (Fs_compat.capability_recovery_failure_phase interruption
        = Fs_compat.Recovery_prepare);
     check bool "pre-transition cancellation records no mutation" true
       (Fs_compat.capability_recovery_failure_effect interruption
        = Fs_compat.Recovery_no_record_change));
  check bool "no write primary was interrupted" true
    (Option.is_none cancellation.interrupted_primary_failure);
  check string "target remains unchanged" "old" (read_file target);
  check (list string) "no staging entry was created" [ "target" ]
    (directory_entries directory)
;;

let test_closed_recovery_access_is_explicit_primary_failure ~fs () =
  let closed_access = ref None in
  with_publication_recovery_access ~fs (fun access ->
    closed_access := Some access);
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_parent_capability ~fs directory @@ fun parent ->
  let recovery =
    match !closed_access with
    | Some recovery -> recovery
    | None -> fail "test recovery access was not captured"
  in
  match
    replace_capability_file
      ~recovery
      ~allowed_root_path:directory
      ~parent
      ~leaf:"target"
      ~permissions:0o640
      "new"
  with
  | Ok () -> fail "replace used a closed Keeper recovery lane"
  | Error error ->
    check bool "replace operation retained" true
      (error.operation = Fs_compat.Atomic_replace_operation);
    check bool "closed lane leaves target unchanged" true
      (error.target_effect = Fs_compat.Target_unchanged);
    (match error.primary_failure with
     | Fs_compat.Recovery_access_primary_failure
         Fs_compat.Recovery_access_not_available -> ()
     | Fs_compat.Write_primary_failure failure ->
       fail (Fs_compat.capability_write_failure_to_string failure)
     | Fs_compat.Recovery_primary_failure failure ->
       fail (Fs_compat.capability_recovery_failure_to_string failure));
    check string "closed lane cannot mutate target" "old" (read_file target)
;;

let test_staging_capability_close_failure_retains_replace_effect ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "old";
  with_replace_context ~fs directory @@ fun parent recovery ->
  match
    replace_capability_file_for_testing
      ~before_stage:(function
        | Fs_compat.Close_staging_directory -> raise Exit
        | _ -> ())
      ~recovery
      ~allowed_root_path:directory
      ~parent
      ~leaf:"target"
      ~permissions:0o640
      "new"
  with
  | Ok () -> fail "fault-injected staging close unexpectedly succeeded"
  | Error error ->
    let failure = require_write_primary_failure error in
    check bool "replace operation retained" true
      (error.operation = Fs_compat.Atomic_replace_operation);
    check bool "staging close is the primary stage" true
      (failure.stage = Fs_compat.Close_staging_directory);
    check bool "published target effect survives capability close failure" true
      (error.target_effect = Fs_compat.Target_replaced);
    check string "published content remains visible" "new" (read_file target);
    check (list string) "staging path remains removed" [ "target" ]
      (directory_entries directory)
;;

let test_directory_sync_failure_is_typed ~fs () =
  with_tmp_dir @@ fun directory ->
  with_parent_capability ~fs directory @@ fun parent ->
  match
    Capability_write_test.sync_directory_capability
      ~before_stage:(function
        | Fs_compat.Sync_parent -> raise Exit
        | _ -> ())
      parent
  with
  | Ok () -> fail "fault-injected directory sync unexpectedly succeeded"
  | Error error ->
    check bool "directory sync stage" true
      (error.failure.stage = Fs_compat.Sync_parent)
;;

let test_open_capability_append_writes_complete_large_payload ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "before:";
  let payload = String.make ((1024 * 1024) + 19) 'x' in
  with_parent_capability ~fs directory @@ fun parent ->
  let outcome =
    Eio.Switch.run @@ fun sw ->
    let file =
      Fs_compat.open_capability_append_file
        ~sw
        ~parent
        ~leaf:"target"
      |> require_append_file
    in
    Fs_compat.append_capability_observed file payload
  in
  check int "all requested append bytes written" (String.length payload)
    outcome.bytes_written;
  check bool "append write succeeded" true (Option.is_none outcome.write_failure);
  check bool "append sync succeeded" true (Option.is_none outcome.sync_failure);
  check bool "append target binding retained" true
    (outcome.target_binding = Fs_compat.Capability_append_target_verified);
  check string "large append is complete" ("before:" ^ payload) (read_file target)
;;

let test_append_reports_detached_inode_after_external_replace ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  let detached = Filename.concat directory "detached" in
  write_file target "before:";
  with_parent_capability ~fs directory @@ fun parent ->
  let outcome =
    Eio.Switch.run @@ fun sw ->
    let file =
      Fs_compat.open_capability_append_file
        ~sw
        ~parent
        ~leaf:"target"
      |> require_append_file
    in
    Fs_compat.Capability_append_for_testing.append_capability_observed
      ~after_write:(fun () ->
        Unix.rename target detached;
        write_file target "replacement")
      file
      "suffix"
  in
  check int "detached append byte count retained" 6 outcome.bytes_written;
  check bool "external replace is reported" true
    (outcome.target_binding = Fs_compat.Capability_append_target_changed);
  check string "current leaf is not misreported as appended" "replacement"
    (read_file target);
  check string "written bytes remain inspectable on detached inode"
    "before:suffix"
    (read_file detached)
;;

let test_partial_append_failure_is_synced_without_rollback () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "before:";
  let fd =
    Unix.openfile target [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CLOEXEC ] 0
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
       let writes = ref 0 in
       let io : Fs_compat.capability_append_io_for_testing =
         { write_substring =
             (fun fd content offset length ->
                incr writes;
                if !writes = 1
                then Unix.write_substring fd content offset (min 3 length)
                else raise (Unix.Unix_error (Unix.ENOSPC, "write", "target")))
         ; fsync = Unix.fsync
         }
       in
       let outcome =
         Fs_compat.Capability_append_for_testing.append_fd_observed
           ~io
           ~fd
           "abcdef"
       in
       check int "partial byte count retained" 3 outcome.bytes_written;
       check bool "write failure retained" true
         (Option.is_some outcome.write_failure);
       check bool "partial bytes were synced" true
         (Option.is_none outcome.sync_failure);
       check bool "fd-only core leaves target unchecked" true
         (outcome.target_binding
          = Fs_compat.Capability_append_target_not_checked));
  check string "partial bytes remain without destructive rollback"
    "before:abc"
    (read_file target)
;;

let test_append_sync_failure_is_explicit () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  write_file target "before:";
  let fd =
    Unix.openfile target [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CLOEXEC ] 0
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
       let io : Fs_compat.capability_append_io_for_testing =
         { write_substring = Unix.write_substring
         ; fsync =
             (fun _ -> raise (Unix.Unix_error (Unix.EIO, "fsync", "target")))
         }
       in
       let outcome =
         Fs_compat.Capability_append_for_testing.append_fd_observed
           ~io
           ~fd
           "suffix"
       in
       check int "complete bytes retained" 6 outcome.bytes_written;
       check bool "write completed" true (Option.is_none outcome.write_failure);
       check bool "sync failure retained" true
         (Option.is_some outcome.sync_failure);
       check bool "fd-only core leaves target unchecked" true
         (outcome.target_binding
          = Fs_compat.Capability_append_target_not_checked));
  check string "visible append is not hidden by sync failure"
    "before:suffix"
    (read_file target)
;;

(* Fixtures may deliberately leave sealed or identity-replaced directories.
   Restore modes only inside this fresh test-owned tree before normal teardown. *)
let with_directory_fixture f =
  with_tmp_dir @@ fun root ->
  let rec writable path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
      Unix.chmod path 0o700;
      Sys.readdir path |> Array.iter (fun leaf -> writable (Filename.concat path leaf))
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> ()
  in
  Fun.protect ~finally:(fun () -> writable root) (fun () -> f root)
;;

let captured_directory files =
  match Fs_compat.directory_payload files with
  | Ok payload -> payload
  | Error error -> fail (Fs_compat.directory_payload_error_to_string error)
;;

let snapshot_payload () =
  captured_directory
    [ { Fs_compat.leaf = "hosts.yml"; content = "exact\000\255\r\n"; permissions = 0o400 }
    ; { Fs_compat.leaf = "config.yml"; content = "configuration"; permissions = 0o400 }
    ]
;;

let publish_directory ~before_stage ~recovery ~directory ~parent payload =
  let target = require_recovery_target ~allowed_root_path:directory
      ~parent ~leaf:"snapshot" ~permissions:0o500 in
  Capability_write_test.create_capability_directory_exclusive
    ~before_stage ~recovery ~parent ~target payload
;;

let check_directory_recovery_count recovery area count =
  let module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing in
  match Recovery_test.record_names recovery ~area with
  | Ok names -> check int "exact recovery record count" count (List.length names)
  | Error Recovery_test.Keeper_lane_not_available -> fail "recovery lane unavailable"
;;

let test_directory_payload_validation () =
  List.iter (fun leaf ->
    match Fs_compat.directory_payload
      [{ Fs_compat.leaf; content = "bytes"; permissions = 0o400 }] with
    | Error (Fs_compat.Invalid_directory_leaf observed) ->
      check string "exact rejected leaf" leaf observed
    | Ok _ | Error (Fs_compat.Duplicate_directory_leaf _
                  | Fs_compat.Invalid_directory_file_permissions _) ->
      failf "unsafe payload leaf accepted or misclassified: %S" leaf)
    [""; "."; ".."; "nested/file"; "../outside"; "/absolute"; "bad\000leaf"];
  let file : Fs_compat.directory_file =
    { leaf = "hosts.yml"; content = "bytes"; permissions = 0o400 } in
  (match Fs_compat.directory_payload [file; file] with
   | Error (Fs_compat.Duplicate_directory_leaf "hosts.yml") -> ()
   | Ok _ | Error _ -> fail "duplicate payload leaf not refused");
  List.iter (fun permissions ->
    match Fs_compat.directory_payload [{file with permissions}] with
    | Error (Fs_compat.Invalid_directory_file_permissions observed) ->
      check int "invalid mode retained" permissions observed.permissions
    | Ok _ | Error _ -> fail "invalid payload mode not refused") [-1; 0o10000];
  ignore (captured_directory [] : Fs_compat.directory_payload)
;;

let test_directory_publication_success ~fs () =
  with_directory_fixture @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  let target = require_recovery_target ~allowed_root_path:directory ~parent
      ~leaf:"snapshot" ~permissions:0o500 in
  require_ok (Fs_compat.create_capability_directory_exclusive
                ~recovery ~parent ~target (snapshot_payload ()));
  let path = Filename.concat directory "snapshot" in
  check int "directory sealed to requested mode" 0o500 (Unix.stat path).st_perm;
  check (list string) "complete flat snapshot" ["config.yml"; "hosts.yml"] (directory_entries path);
  check string "binary bytes preserved" "exact\000\255\r\n"
    (read_file (Filename.concat path "hosts.yml"));
  List.iter (fun leaf -> check int "file sealed to requested mode" 0o400
    (Unix.stat (Filename.concat path leaf)).st_perm) ["hosts.yml"; "config.yml"];
  check (list string) "no leftover stage" ["snapshot"] (directory_entries directory);
  check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 0;
  let empty = require_recovery_target ~allowed_root_path:directory ~parent
      ~leaf:"empty" ~permissions:0o750 in
  require_ok (Fs_compat.create_capability_directory_exclusive
                ~recovery ~parent ~target:empty (captured_directory []));
  check (list string) "empty snapshot is supported" [] (directory_entries (Filename.concat directory "empty"));
  check int "directory mode comes from target" 0o750
    (Unix.stat (Filename.concat directory "empty")).st_perm;
  let sealed = require_recovery_target ~allowed_root_path:directory ~parent
      ~leaf:"inaccessible" ~permissions:0 in
  require_ok (Fs_compat.create_capability_directory_exclusive
                ~recovery ~parent ~target:sealed (snapshot_payload ()));
  check int "mode 000 still permits held-capability publication validation" 0
    (Unix.stat (Filename.concat directory "inaccessible")).st_perm
;;

let test_directory_publication_private_and_no_replace ~fs () =
  with_directory_fixture @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  let target = Filename.concat directory "snapshot" in
  let foreign = ref None in
  (match publish_directory ~recovery ~directory ~parent (snapshot_payload ())
    ~before_stage:(function
      | Fs_compat.Publish_exclusive ->
        check bool "target absent before publish" false (Sys.file_exists target);
        let stage = only_entry_except directory [] in
        let payload = Filename.concat directory stage in
        check int "private directory already sealed" 0o500 (Unix.stat payload).st_perm;
        check string "private bytes complete" "exact\000\255\r\n"
          (read_file (Filename.concat payload "hosts.yml"));
        Unix.mkdir target 0o700;
        write_file (Filename.concat target "foreign") "untouched";
        foreign := Some (Unix.stat target).st_ino
      | _ -> ()) with
   | Ok () -> fail "actual no-replace syscall overwrote foreign directory"
   | Error error ->
     check bool "EEXIST leaves target known unchanged" true
       (error.target_effect = Fs_compat.Target_unchanged);
     let failure = require_write_primary_failure error in
     check bool "actual rename refused" true (failure.stage = Fs_compat.Publish_exclusive);
     (match failure.cause with
      | Fs_compat.Operation_failed {exception_ = Unix.Unix_error (Unix.EEXIST, _, _); _} -> ()
      | _ -> fail "directory test did not exercise no-replace syscall");
     check int "sealed payload cleanup succeeded" 0 (List.length error.cleanup_failures));
  check (option int) "foreign directory inode retained" !foreign (Some (Unix.stat target).st_ino);
  check string "foreign bytes retained" "untouched" (read_file (Filename.concat target "foreign"));
  check (list string) "only foreign target remains" ["snapshot"] (directory_entries directory)
;;

let test_directory_sealed_cleanup ~fs () =
  with_directory_fixture @@ fun directory ->
  with_replace_context ~fs directory @@ fun parent recovery ->
  let syncs = ref 0 in
  (match publish_directory ~recovery ~directory ~parent (snapshot_payload ())
     ~before_stage:(function
       | Fs_compat.Sync_payload ->
         incr syncs;
         if !syncs = 3 then (
           let stage = only_entry_except directory [] in
           let payload = Filename.concat directory stage in
           check int "fault occurs after directory sealed" 0o500 (Unix.stat payload).st_perm;
           raise Exit)
       | _ -> ()) with
   | Ok () -> fail "sealed-directory sync failure became success"
   | Error error ->
     check bool "no public rename occurred" true (error.target_effect = Fs_compat.Target_unchanged);
     check int "held fd cleanup succeeds despite mode 0500" 0 (List.length error.cleanup_failures));
  check (list string) "complete owned stage removed" [] (directory_entries directory);
  check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 0
;;

let test_directory_cleanup_preserves_replaced_entries ~fs () =
  List.iter (fun replacement ->
    with_directory_fixture @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    let planted = ref None in
    (match publish_directory ~recovery ~directory ~parent (snapshot_payload ())
       ~before_stage:(function
         | Fs_compat.Publish_exclusive ->
           let stage = only_entry_except directory [] in
           let stage_path = Filename.concat directory stage in
           let payload = stage_path in
           (match replacement with
            | `Child ->
              Unix.chmod payload 0o700;
              let child = Filename.concat payload "hosts.yml" in
              Unix.rename child (Filename.concat payload "original-hosts.yml");
              write_file child "foreign";
              planted := Some (child, (Unix.stat child).st_ino)
            | `Stage ->
              Unix.rename stage_path (Filename.concat directory "detached-stage");
              Unix.mkdir stage_path 0o700;
              write_file (Filename.concat stage_path "foreign") "foreign";
              planted := Some (stage_path, (Unix.lstat stage_path).st_ino)
            | `Symlink ->
              Unix.rename stage_path (Filename.concat directory "detached-stage");
              let sentinel = Filename.concat directory "foreign-target" in
              write_file sentinel "foreign";
              Unix.symlink sentinel stage_path;
              planted := Some (stage_path, (Unix.lstat stage_path).st_ino));
           raise Exit
         | _ -> ()) with
     | Ok () -> fail "injected stage replacement became success"
     | Error error ->
       check bool "cleanup reports lost authority" true (error.cleanup_failures <> []));
    (match !planted with
     | None -> fail "replacement callback not reached"
     | Some (path, inode) ->
       check int "foreign inode never removed" inode (Unix.lstat path).st_ino);
    check bool "no public target" false (Sys.file_exists (Filename.concat directory "snapshot"));
    check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 1)
    [`Child; `Stage; `Symlink]
;;

let test_directory_post_publish_failure ~fs () =
  List.iter (fun cleanup_sync_fails ->
    with_directory_fixture @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    (match publish_directory ~recovery ~directory ~parent (snapshot_payload ())
       ~before_stage:(function
         | Fs_compat.Sync_parent -> raise Exit
         | Fs_compat.Cleanup_sync_parent when cleanup_sync_fails -> raise Exit
         | _ -> ()) with
     | Ok () -> fail "post-publish sync failure became success"
     | Error error ->
       check bool "known rename effect retained" true (error.target_effect = Fs_compat.Target_created);
       check bool "exact sync failure retained" true
         ((require_write_primary_failure error).stage = Fs_compat.Sync_parent);
       check bool "cleanup sync failure is independently typed" cleanup_sync_fails
         (has_write_cleanup_stage Fs_compat.Cleanup_sync_parent error));
    let path = Filename.concat directory "snapshot" in
    check string "published bytes never cleaned" "exact\000\255\r\n" (read_file (Filename.concat path "hosts.yml"));
    check int "published directory remains sealed" 0o500 (Unix.stat path).st_perm;
    check (list string) "published final is sole target entry" ["snapshot"] (directory_entries directory);
    check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned
      (if cleanup_sync_fails then 1 else 0))
    [false; true]
;;

let test_directory_final_inventory_refuses_drift ~fs () =
  List.iter (fun replacement ->
    with_directory_fixture @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    let foreign = ref None in
    (match publish_directory ~recovery ~directory ~parent (snapshot_payload ())
       ~before_stage:(function
         | Fs_compat.Publish_exclusive ->
           let stage = only_entry_except directory [] in
           let stage_path = Filename.concat directory stage in
           let payload = stage_path in
           Unix.chmod payload 0o700;
           let path = Filename.concat payload "hosts.yml" in
           (match replacement with
            | `Child -> Unix.rename path (Filename.concat directory "original-hosts.yml")
            | `Unknown -> ());
           let path = match replacement with
             | `Child -> path | `Unknown -> Filename.concat payload "foreign" in
           write_file path "foreign bytes";
           foreign := Some (path, (Unix.stat path).st_ino)
         | _ -> ()) with
     | Ok () -> fail "foreign snapshot content was published"
     | Error error ->
       check bool "foreign content refused before rename" true
         (error.target_effect = Fs_compat.Target_unchanged);
       let failure = require_write_primary_failure error in
       check bool "final payload identity/inventory check refused" true
         (failure.stage = Fs_compat.Verify_entry_identity));
    check bool "public target absent after drift" false
      (Sys.file_exists (Filename.concat directory "snapshot"));
    (match !foreign with
     | None -> fail "foreign content hook not reached"
     | Some (path, inode) ->
       check int "foreign entry retained for reconciliation" inode (Unix.stat path).st_ino;
       check string "foreign bytes preserved" "foreign bytes" (read_file path));
    check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 1)
    [`Child; `Unknown]
;;

let test_directory_cleanup_rechecks_after_hooks ~fs () =
  List.iter (fun replacement ->
    with_directory_fixture @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    let unlink_hooks = ref 0 in
    let foreign = ref None in
    (match publish_directory ~recovery ~directory ~parent (snapshot_payload ())
       ~before_stage:(function
         | Fs_compat.Publish_exclusive -> raise Exit
         | Fs_compat.Cleanup_unlink ->
           incr unlink_hooks;
           (* First callback wraps directory cleanup. Second is the actual
              first child unlink, after all children were already verified. *)
           if !unlink_hooks = 2 then (
             let stage = only_entry_except directory [] in
             let stage_path = Filename.concat directory stage in
             let payload = stage_path in
             let path = match replacement with
               | `Child ->
                 let child = Filename.concat payload "config.yml" in
                 Unix.rename child (Filename.concat payload "original-config.yml");
                 write_file child "foreign bytes";
                 child
               | `Payload ->
                 Unix.rename payload (Filename.concat directory "detached-payload");
                 Unix.mkdir payload 0o700;
                 payload
             in
             foreign := Some (path, (Unix.stat path).st_ino))
         | _ -> ()) with
     | Ok () -> fail "cleanup fault became success"
     | Error error ->
       check bool "replacement detected after cleanup hook" true
         (has_write_cleanup_stage Fs_compat.Cleanup_verify_identity error));
    (match !foreign with
     | None -> fail "per-child cleanup hook not reached"
     | Some (path, inode) ->
       check int "foreign entry not unlinked or removed" inode (Unix.stat path).st_ino);
    check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 1)
    [`Child; `Payload]
;;

let test_directory_cancellation ~fs () =
  List.iter (fun after_rename ->
    with_directory_fixture @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    let syncs = ref 0 in
    let cancellation =
      try
        Eio.Cancel.sub (fun context ->
          ignore (publish_directory ~recovery ~directory ~parent (snapshot_payload ())
            ~before_stage:(function
              | Fs_compat.Sync_payload when not after_rename ->
                incr syncs;
                if !syncs = 3 then (Eio.Cancel.cancel context Exit; Eio.Fiber.check ())
              | Fs_compat.Publish_exclusive when after_rename -> Eio.Cancel.cancel context Exit
              | _ -> ())));
        None
      with
      | Eio.Cancel.Cancelled (Fs_compat.Capability_write_cancelled (_, evidence)) -> Some evidence
      | Eio.Cancel.Cancelled _ when not after_rename -> None
    in
    if after_rename then (
      (match cancellation with
       | None -> fail "post-publish cancellation lost typed effect"
       | Some evidence -> check bool "cancelled commit records creation" true
           (evidence.target_effect = Fs_compat.Target_created));
      check string "protected commit finishes complete directory" "exact\000\255\r\n"
        (read_file (Filename.concat (Filename.concat directory "snapshot") "hosts.yml")))
    else check (list string) "precommit cancellation cleans sealed directory" [] (directory_entries directory);
    check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 0)
    [false; true]
;;

let test_directory_outer_stage_removal_rechecks_after_hook ~fs () =
    with_directory_fixture @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    let foreign = ref None in
    let plant_empty_foreign_stage () =
      let leaf = only_entry_except directory ["snapshot"] in
      let path = Filename.concat directory leaf in
      Unix.rename path (Filename.concat directory "detached-stage");
      Unix.mkdir path 0o700;
      foreign := Some (path, (Unix.stat path).st_ino)
    in
    (match publish_directory ~recovery ~directory ~parent (snapshot_payload ())
       ~before_stage:(function
         | Fs_compat.Publish_exclusive -> raise Exit
         | Fs_compat.Cleanup_remove_staging_directory ->
           plant_empty_foreign_stage ()
         | _ -> ()) with
     | Ok () -> fail "foreign outer stage was removed"
     | Error error ->
       check bool "rename effect reflects the actual phase" true
         (error.target_effect = Fs_compat.Target_unchanged);
       check bool "outer stage authority failure retained" true
         (has_write_cleanup_stage Fs_compat.Cleanup_verify_staging_directory_identity error));
    (match !foreign with
     | None -> fail "outer stage removal hook not reached"
     | Some (path, inode) ->
       check int "foreign empty directory not removed" inode (Unix.stat path).st_ino);
    let final = Filename.concat directory "snapshot" in
    check bool "prepublish cleanup did not create final" false (Sys.file_exists final);
    check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 1
;;

let test_directory_first_public_observation_is_sealed ~fs () =
  List.iter (fun permissions ->
    with_directory_fixture @@ fun directory ->
    with_replace_context ~fs directory @@ fun parent recovery ->
    let target = require_recovery_target ~allowed_root_path:directory ~parent
        ~leaf:"snapshot" ~permissions in
    let final = Filename.concat directory "snapshot" in
    let staged = ref None in
    let observed_public = ref false in
    require_ok (Capability_write_test.create_capability_directory_exclusive
      ~recovery ~parent ~target (snapshot_payload ())
      ~before_stage:(function
        | Fs_compat.Publish_exclusive ->
          check bool "public leaf absent before sealed rename" false (Sys.file_exists final);
          let stage = Filename.concat directory (only_entry_except directory []) in
          let stat = Unix.stat stage in
          check int "stage sealed before namespace publication" permissions stat.st_perm;
          staged := Some (stage, stat.st_dev, stat.st_ino)
        | Fs_compat.Sync_parent ->
          let stat = Unix.stat final in
          check int "first public observation is already sealed" permissions stat.st_perm;
          (match !staged with
           | None -> fail "private stage not observed"
           | Some (stage, dev, inode) ->
             check int "same directory inode was published" inode stat.st_ino;
             check int "same device was published" dev stat.st_dev;
             check bool "canonical stage name moved away" false (Sys.file_exists stage));
          observed_public := true
        | _ -> ()));
    check bool "postrename observation was exercised" true !observed_public;
    check (list string) "only completed public snapshot remains" ["snapshot"]
      (directory_entries directory);
    (* Mode 000 is checked before this fixture-only permission restoration. *)
    Unix.chmod final 0o500;
    check string "sealed publication retains exact bytes" "exact\000\255\r\n"
      (read_file (Filename.concat final "hosts.yml"));
    List.iter (fun leaf -> check int "published file remains sealed" 0o400
      (Unix.stat (Filename.concat final leaf)).st_perm) ["hosts.yml"; "config.yml"];
    check_directory_recovery_count recovery Fs_compat_test_support.Publication_recovery_for_testing.Owned 0)
    [0o500; 0]
;;

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  run
    "fs_compat capability write"
    [ ( "publication"
      , [ test_case "directory payload rejects invalid flat entries" `Quick test_directory_payload_validation
        ; test_case "exclusive directory bytes modes and empty payload" `Quick (test_directory_publication_success ~fs)
        ; test_case "exclusive directory stays private and refuses foreign final" `Quick (test_directory_publication_private_and_no_replace ~fs)
        ; test_case "sealed directory cleanup uses held descriptor" `Quick (test_directory_sealed_cleanup ~fs)
        ; test_case "directory cleanup preserves replaced entries" `Quick (test_directory_cleanup_preserves_replaced_entries ~fs)
        ; test_case "directory post-publish failure retains effect and recovery" `Quick (test_directory_post_publish_failure ~fs)
        ; test_case "directory publish validates final child identities and inventory" `Quick (test_directory_final_inventory_refuses_drift ~fs)
        ; test_case "directory cleanup rechecks authority after hooks" `Quick (test_directory_cleanup_rechecks_after_hooks ~fs)
        ; test_case "directory cancellation preserves publication boundary" `Quick (test_directory_cancellation ~fs)
        ; test_case "directory outer stage removal rechecks after hooks" `Quick (test_directory_outer_stage_removal_rechecks_after_hook ~fs)
        ; test_case "directory is sealed from first public observation" `Quick (test_directory_first_public_observation_is_sealed ~fs)
        ; test_case "standalone exclusive publication reopens its owner" `Quick
            (test_standalone_exclusive_publication ~fs)
        ; test_case "atomic replace mode" `Quick
            (test_atomic_replace_preserves_requested_mode ~fs)
        ; test_case "symlink lexical replace" `Quick
            (test_atomic_replace_replaces_symlink_not_referent ~fs)
        ; test_case "large payload complete" `Quick
            (test_atomic_replace_writes_complete_large_payload ~fs)
        ; test_case "replace fatal and cancellation preserve backtrace" `Quick
            (test_replace_nonrecoverable_exceptions_preserve_backtrace ~fs)
        ; test_case "create fatal and cancellation preserve backtrace" `Quick
            (test_create_nonrecoverable_exceptions_preserve_backtrace ~fs)
        ; test_case "cleanup fatal preserves backtrace" `Quick
            (test_cleanup_fatal_exception_preserves_backtrace ~fs)
        ; test_case "replace cleanup cancellation preserves authority" `Quick
            (test_replace_direct_cleanup_cancellation_preserves_authority ~fs)
        ; test_case
            "cleanup cancellation retains earlier staging unlink failure"
            `Quick
            (test_replace_cleanup_cancellation_retains_earlier_cleanup_failure ~fs)
        ; test_case
            "cancelled replacement retains cleanup facts after second cancellation"
            `Quick
            (test_cancelled_replace_retains_cleanup_facts_on_second_cancellation ~fs)
        ; test_case
            "cancelled create preserves initial cancellation during cleanup"
            `Quick
            (test_cancelled_create_preserves_initial_cancellation_during_cleanup ~fs)
        ; test_case "create cleanup cancellation preserves authority" `Quick
            (test_create_direct_cleanup_cancellation_preserves_authority ~fs)
        ; test_case "recovery cancellation preserves authority" `Quick
            (test_recovery_cancellation_preserves_authority_and_backtrace ~fs)
        ; test_case "actual recovery unlink cancellation retains effect" `Quick
            (test_recovery_unlink_cancellation_retains_actual_effect ~fs ~write_primary:false)
        ; test_case "write primary survives actual recovery unlink cancellation" `Quick
            (test_recovery_unlink_cancellation_retains_actual_effect ~fs ~write_primary:true)
        ; test_case "typed parent components" `Quick
            (test_atomic_replace_uses_typed_parent_components ~fs)
        ; test_case "owned restrictive staging directory" `Quick
            (test_atomic_replace_owns_restrictive_staging_directory ~fs)
        ; test_case "replace preflight keeps target state" `Quick
            (test_replace_preflight_failure_keeps_known_target_state ~fs)
        ; test_case "replace preflight detects payload swap" `Quick
            (test_replace_preflight_detects_payload_leaf_swap ~fs)
        ; test_case "pinned staging payload resists name swap" `Quick
            (test_staging_name_swap_does_not_redirect_pinned_payload ~fs)
        ; test_case "append and replace share target identity lease" `Quick
            (test_append_and_replace_share_existing_target_lease ~fs)
        ; test_case "hard-link replaces share target identity lease" `Quick
            (test_hard_link_replaces_share_existing_target_lease ~fs)
        ; test_case "replace reobserves binding after lease acquisition" `Quick
            (test_replace_reobserves_binding_after_lease_acquisition ~fs)
        ; test_case "existing replace reobserves binding at publication" `Quick
            (test_existing_replace_reobserves_binding_at_publication ~fs)
        ; test_case "existing replace yields to absent publication" `Quick
            (test_existing_replace_yields_to_cooperative_absent_publication
               ~fs)
        ; test_case "absent replace reobserves binding at publication" `Quick
            (test_absent_replace_reobserves_binding_at_publication ~fs)
        ; test_case "existing publication guard blocks absent sibling" `Quick
            (test_existing_publication_guard_blocks_absent_sibling ~fs)
        ; test_case "absent replace covers publication transition" `Quick
            (test_absent_replace_blocks_visible_and_absent_sibling_mutations
               ~fs)
        ; test_case "exclusive create keeps pre-publication work private" `Quick
            (test_exclusive_create_remains_private_under_parent_lease ~fs)
        ; test_case "existing target permits absent sibling progress" `Quick
            (test_existing_target_lease_allows_absent_sibling_progress
               ~fs)
        ; test_case "append lease blocks replace then releases" `Quick
            (test_append_lease_blocks_replace_then_releases ~fs)
        ; test_case "independent targets progress concurrently" `Quick
            (test_independent_targets_progress_without_global_io_serialization
               ~fs)
        ; test_case "exclusive create" `Quick
            (test_create_exclusive_does_not_overwrite ~fs)
        ; test_case "exclusive create refuses post-check foreign entries" `Quick
            (test_create_exclusive_refuses_postcheck_intruder ~fs)
        ; test_case "exclusive create success" `Quick
            (test_create_exclusive_success ~fs)
        ; test_case "exclusive create failure state" `Quick
            (test_create_failure_preserves_private_boundary ~fs)
        ; test_case "exclusive create parent sync failure" `Quick
            (test_create_parent_sync_failure_preserves_complete_effect ~fs)
        ; test_case "parent fsync typed failure" `Quick
            (test_parent_fsync_failure_is_not_success ~fs)
        ; test_case "primary plus cleanup failures" `Quick
            (test_primary_and_cleanup_failures_are_preserved ~fs)
        ; test_case "replace primary plus cleanup cancellation" `Quick
            (test_replace_primary_failure_survives_cleanup_cancellation ~fs)
        ; test_case "create primary plus cleanup cancellation" `Quick
            (test_create_primary_failure_survives_cleanup_cancellation ~fs)
        ; test_case "precommit cancellation" `Quick
            (test_precommit_cancellation_cleans_staging ~fs)
        ; test_case "pending payload sync cancellation" `Quick
            (test_pending_payload_sync_cancellation_does_not_publish ~fs)
        ; test_case "cleanup identity drift preserves unknown payload" `Quick
            (test_cleanup_identity_failure_never_unlinks_unknown_payload ~fs)
        ; test_case "exclusive create cancellation" `Quick
            (test_exclusive_create_cancellation_keeps_public_leaf_absent ~fs)
        ; test_case "commit cancellation" `Quick
            (test_commit_cancellation_finishes_durable_replace ~fs)
        ; test_case "exclusive create commit cancellation" `Quick
            (test_create_commit_cancellation_reports_complete_effect ~fs)
        ; test_case "split write leaf validation" `Quick
            (test_split_writes_reject_non_leaf_path ~fs)
        ; test_case "replace rejects directory and fifo targets" `Quick
            (test_replace_rejects_directory_and_fifo_targets ~fs)
        ; test_case "recovery transition cancellation is typed" `Quick
            (test_recovery_transition_cancellation_is_typed ~fs)
        ; test_case "closed recovery access is explicit" `Quick
            (test_closed_recovery_access_is_explicit_primary_failure ~fs)
        ; test_case "staging close retains replace effect" `Quick
            (test_staging_capability_close_failure_retains_replace_effect ~fs)
        ; test_case "directory sync typed failure" `Quick
            (test_directory_sync_failure_is_typed ~fs)
        ; test_case "large capability append" `Quick
            (test_open_capability_append_writes_complete_large_payload ~fs)
        ; test_case "append detects detached inode" `Quick
            (test_append_reports_detached_inode_after_external_replace ~fs)
        ; test_case "partial append is observed" `Quick
            test_partial_append_failure_is_synced_without_rollback
        ; test_case "append sync failure" `Quick
            test_append_sync_failure_is_explicit
        ] )
    ]
;;
