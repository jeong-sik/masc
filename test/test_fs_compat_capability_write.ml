open Alcotest

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
    Fs_compat.open_publication_recovery_registry
      ~sw
      ~registry_root:Eio.Path.(fs / registry_directory)
  with
  | Error error ->
    fail (Fs_compat.publication_recovery_registry_error_to_string error)
  | Ok registry ->
    (match Fs_compat.inventory_publication_recovery_owners registry with
     | Error error ->
       fail
         (Fs_compat.publication_recovery_owner_inventory_error_to_string
            error)
     | Ok [] ->
       (match
          Fs_compat.with_publication_recovery_lane
            ~registry
            ~owner:"capability-write-test"
            f
        with
        | Ok value -> value
        | Error error ->
          fail
            (Fs_compat.publication_recovery_lane_open_error_to_string
               error))
     | Ok rows ->
       failf
         "fresh publication recovery fixture unexpectedly contained owners: %s"
         (String.concat
            "; "
            (List.map
               Fs_compat.publication_recovery_owner_inventory_row_to_string
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
    Fs_compat.atomic_replace_recovery_target
      ~allowed_root_path
      ~allowed_root_device:root.dev
      ~allowed_root_inode:root.ino
      ~parent_components:[]
      ~target_leaf:leaf
      ~permissions
  with
  | Ok target -> target
  | Error error ->
    fail (Fs_compat.atomic_replace_recovery_target_error_to_string error)
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
  Fs_compat.Capability_write_for_testing.replace_capability_file
    ~before_stage
    ~recovery
    ~parent
    ~target
    content
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
      Fs_compat.atomic_replace_recovery_target
        ~allowed_root_path:directory
        ~allowed_root_device:allowed_root_stat.dev
        ~allowed_root_inode:allowed_root_stat.ino
        ~parent_components:[ "nested" ]
        ~target_leaf:"target"
        ~permissions:0o640
    with
    | Ok target -> target
    | Error error ->
      fail (Fs_compat.atomic_replace_recovery_target_error_to_string error)
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
         | Fs_compat.Publish_replace ->
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

let test_append_and_replace_share_nonblocking_entry_lease ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
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
  let append_outcome, alias_rejected =
    Eio.Switch.run @@ fun append_sw ->
    let file =
      Fs_compat.open_capability_append_file
        ~sw:append_sw
        ~parent
        ~leaf:"target"
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
  check bool "append immediately reports entry contention" true
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
  check bool "atomic writer releases the entry lease" true
    (Option.is_none append_after_release.write_failure);
  check string "replacement completes before the later append"
    "replacementafter-release"
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
  with_parent_capability ~fs directory @@ fun parent ->
  (match
     Fs_compat.create_capability_file_exclusive
       ~parent
       ~leaf:"target"
       ~permissions:0o644
       "new"
   with
   | Ok () -> fail "exclusive create overwrote an existing entry"
   | Error error ->
     let failure = require_write_primary_failure error in
     check bool "failure is create stage" true
       (failure.stage = Fs_compat.Create_target_entry);
     check bool "target is known unchanged" true
       (error.target_effect = Fs_compat.Target_unchanged));
  check string "existing payload retained" "existing" (read_file target)
;;

let test_create_exclusive_success ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_parent_capability ~fs directory @@ fun parent ->
  require_ok
    (Fs_compat.create_capability_file_exclusive
       ~parent
       ~leaf:"target"
       ~permissions:0o640
       "created");
  check string "payload created" "created" (read_file target);
  check int "requested mode applied" 0o640 ((Unix.stat target).st_perm land 0o777)
;;

let test_create_failure_leaves_public_leaf ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_parent_capability ~fs directory @@ fun parent ->
  (match
     Fs_compat.Capability_write_for_testing.create_capability_file_exclusive
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
     check bool "incomplete public creation is explicit" true
       (error.target_effect = Fs_compat.Target_created_incomplete));
  check bool "public leaf is not unsafely unlinked" true (Sys.file_exists target);
  check string "written bytes remain observable" "partial" (read_file target);
  check int "pre-fchmod mode remains explicit" 0o600
    ((Unix.stat target).st_perm land 0o777)
;;

let test_create_parent_sync_failure_preserves_complete_effect ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_parent_capability ~fs directory @@ fun parent ->
  (match
     Fs_compat.Capability_write_for_testing.create_capability_file_exclusive
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
  with_parent_capability ~fs directory @@ fun parent ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (Fs_compat.Capability_write_for_testing.create_capability_file_exclusive
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

let test_exclusive_create_cancellation_reports_incomplete_entry ~fs () =
  with_tmp_dir @@ fun directory ->
  let target = Filename.concat directory "target" in
  with_parent_capability ~fs directory @@ fun parent ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (Fs_compat.Capability_write_for_testing.create_capability_file_exclusive
             ~before_stage:(function
               | Fs_compat.Apply_permissions ->
                 Eio.Cancel.cancel context Exit;
                 Eio.Fiber.check ()
               | _ -> ())
             ~parent
             ~leaf:"target"
             ~permissions:0o644
             "partial"
           : (unit, Fs_compat.capability_write_error) result));
      None
    with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (_, cancellation)) ->
      Some cancellation
    | Eio.Cancel.Cancelled _ -> fail "typed create cancellation state was lost"
  in
  check (option bool) "incomplete creation effect observed" (Some true)
    (Option.map
       (fun (cancellation : Fs_compat.capability_write_cancellation) ->
          cancellation.target_effect = Fs_compat.Target_created_incomplete)
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
  check bool "incomplete public leaf retained" true (Sys.file_exists target);
  check string "written content remains inspectable" "partial" (read_file target)
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
  with_parent_capability ~fs directory @@ fun parent ->
  let cancellation =
    try
      Eio.Cancel.sub (fun context ->
        ignore
          (Fs_compat.Capability_write_for_testing.create_capability_file_exclusive
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
         Fs_compat.atomic_replace_recovery_target
           ~allowed_root_path:directory
           ~allowed_root_device:root.dev
           ~allowed_root_inode:root.ino
           ~parent_components:[]
           ~target_leaf:leaf
           ~permissions:0o644
       with
       | Ok _ -> failf "replace projection accepted non-leaf path: %S" leaf
       | Error _ -> ());
      match
        Fs_compat.create_capability_file_exclusive
          ~parent
          ~leaf
          ~permissions:0o644
          "payload"
      with
      | Ok () -> failf "exclusive create accepted non-leaf path: %S" leaf
      | Error error ->
        let failure = require_write_primary_failure error in
        check bool ("validation stage for " ^ leaf) true
          (failure.stage = Fs_compat.Validate_leaf))
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
    Fs_compat.Capability_write_for_testing.sync_directory_capability
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

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  run
    "fs_compat capability write"
    [ ( "publication"
      , [ test_case "atomic replace mode" `Quick
            (test_atomic_replace_preserves_requested_mode ~fs)
        ; test_case "symlink lexical replace" `Quick
            (test_atomic_replace_replaces_symlink_not_referent ~fs)
        ; test_case "large payload complete" `Quick
            (test_atomic_replace_writes_complete_large_payload ~fs)
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
        ; test_case "append and replace share entry lease" `Quick
            (test_append_and_replace_share_nonblocking_entry_lease ~fs)
        ; test_case "append lease blocks replace then releases" `Quick
            (test_append_lease_blocks_replace_then_releases ~fs)
        ; test_case "independent targets progress concurrently" `Quick
            (test_independent_targets_progress_without_global_io_serialization
               ~fs)
        ; test_case "exclusive create" `Quick
            (test_create_exclusive_does_not_overwrite ~fs)
        ; test_case "exclusive create success" `Quick
            (test_create_exclusive_success ~fs)
        ; test_case "exclusive create failure state" `Quick
            (test_create_failure_leaves_public_leaf ~fs)
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
            (test_exclusive_create_cancellation_reports_incomplete_entry ~fs)
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
