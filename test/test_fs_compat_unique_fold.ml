open Alcotest
module Fs = Fs_compat
module Fold = Fs.Private_jsonl_fold
module Unique = Fs.Private_jsonl_unique_fold

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK
                     | Unix.S_FIFO | Unix.S_SOCK); _ } -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root f =
  let root = Filename.temp_dir "fs-unique-fold-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let write path bytes =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel bytes)

let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let entries root = Array.to_list (Sys.readdir root) |> List.sort String.compare
let fold path ~f = Fs.fold_private_jsonl_unique_regular_locked_result path ~init:[] ~f
let rows path = fold path ~f:(fun acc row -> row :: acc)

let require_present = function
  | Fs.Private_file_succeeded (Fold.Present { value; rows_end; end_offset }) ->
    value, rows_end, end_offset
  | Fs.Private_file_succeeded Fold.Missing -> fail "existing file reported Missing"
  | Fs.Private_file_failed error -> fail (Unique.error_to_string error)
  | Fs.Private_file_succeeded_with_cleanup_failure _
  | Fs.Private_file_failed_with_cleanup_failure _ -> fail "unexpected descriptor cleanup failure"

let require_error = function
  | Fs.Private_file_failed error -> error
  | Fs.Private_file_succeeded _ -> fail "unsafe observation was accepted"
  | Fs.Private_file_succeeded_with_cleanup_failure _
  | Fs.Private_file_failed_with_cleanup_failure _ -> fail "unexpected descriptor cleanup failure"

let check_binding_refusal expected = function
  | Unique.Binding_refused error -> check bool "exact binding refusal" true (error = expected)
  | (Unique.Non_regular_file _ | Unique.Snapshot_changed | Unique.Operation_failed _) as error ->
    fail (Unique.error_to_string error)

let check_snapshot_changed = function
  | Unique.Snapshot_changed -> ()
  | (Unique.Non_regular_file _ | Unique.Binding_refused _ | Unique.Operation_failed _) as error ->
    fail (Unique.error_to_string error)

let check_unchanged path before bytes directory_entries =
  let after = Unix.lstat path in
  check int "same device" before.Unix.st_dev after.Unix.st_dev;
  check int "same inode" before.Unix.st_ino after.Unix.st_ino;
  check int "same permissions" before.Unix.st_perm after.Unix.st_perm;
  check int "same link count" before.Unix.st_nlink after.Unix.st_nlink;
  check string "same bytes" bytes (read path);
  check (list string) "no lock or stage entries" directory_entries (entries (Filename.dirname path))

let test_absent_root () = with_root (fun root ->
  let parent = Filename.concat root "not-created" in
  let path = Filename.concat (Filename.concat parent "nested") "posts.jsonl" in
  let called = ref false in
  (match fold path ~f:(fun acc _ -> called := true; acc) with
   | Fs.Private_file_succeeded Fold.Missing -> ()
   | Fs.Private_file_succeeded (Fold.Present _) -> fail "absent root became Present"
   | Fs.Private_file_failed error -> fail (Unique.error_to_string error)
   | Fs.Private_file_succeeded_with_cleanup_failure _
   | Fs.Private_file_failed_with_cleanup_failure _ -> fail "absent root had descriptor settlement");
  check bool "no callback" false !called;
  check bool "no parent creation" false (Sys.file_exists parent);
  check (list string) "no directory entries" [] (entries root))

let test_empty_present () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  write path "";
  Unix.chmod path 0o640;
  let before = Unix.lstat path and directory_entries = entries root in
  let value, rows_end, end_offset = require_present (rows path) in
  check (list string) "no rows" [] value;
  check int "rows end" 0 rows_end;
  check int "file end" 0 end_offset;
  check_unchanged path before "" directory_entries)

let test_stream_framing () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  let long = String.make 70000 'a' in
  let bytes = long ^ "\n\nsecond\n{" in
  write path bytes;
  Unix.chmod path 0o444;
  let before = Unix.lstat path and directory_entries = entries root in
  let value, rows_end, end_offset = require_present (rows path) in
  check (list string) "ordered complete rows across buffer boundary"
    [long; ""; "second"] (List.rev value);
  check int "unterminated fragment excluded" (String.length bytes - 1) rows_end;
  check int "full file end retained" (String.length bytes) end_offset;
  check_unchanged path before bytes directory_entries)

let test_symlink_policy () = with_root (fun root ->
  let target = Filename.concat root "target.jsonl" and path = Filename.concat root "posts.jsonl" in
  write target "actual\n";
  Unix.symlink target path;
  let called = ref false in
  require_error (fold path ~f:(fun acc _ -> called := true; acc))
  |> check_binding_refusal (Fs.Unexpected_transaction_file_kind Unix.S_LNK);
  check bool "alias rejected before row decoding" false !called;
  (match Fs.fold_private_jsonl_locked_result path ~init:[] ~f:(fun acc row -> row :: acc) with
   | Fs.Private_file_succeeded (Fold.Present { value = ["actual"]; _ }) -> ()
   | Fs.Private_file_succeeded _ | Fs.Private_file_failed _
   | Fs.Private_file_succeeded_with_cleanup_failure _
   | Fs.Private_file_failed_with_cleanup_failure _ -> fail "existing fold lost symlink support");
  check string "target preserved" "actual\n" (read target);
  check (list string) "only original entries" ["posts.jsonl"; "target.jsonl"] (entries root))

let test_dangling_symlink () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  Unix.symlink (Filename.concat root "absent.jsonl") path;
  require_error (rows path)
  |> check_binding_refusal (Fs.Unexpected_transaction_file_kind Unix.S_LNK);
  check (list string) "dangling alias remains without metadata" ["posts.jsonl"] (entries root))

let test_hardlink_policy () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" and alias = Filename.concat root "alias.jsonl" in
  write path "actual\n";
  Unix.link path alias;
  let called = ref false in
  require_error (fold path ~f:(fun acc _ -> called := true; acc))
  |> check_binding_refusal (Fs.Ambiguous_transaction_file_identity { path; link_count = 2 });
  check bool "multiply linked source rejected before callback" false !called;
  check string "hardlinked source preserved" "actual\n" (read path))

let test_directory_refused () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  Unix.mkdir path 0o750;
  let before = Unix.lstat path in
  (match require_error (rows path) with
   | Unique.Non_regular_file kind -> check bool "actual descriptor kind" true (kind = Unix.S_DIR)
   | (Unique.Snapshot_changed | Unique.Binding_refused _ | Unique.Operation_failed _) as error ->
     fail (Unique.error_to_string error));
  check (list string) "no entries beneath refused directory" [] (entries path);
  check int "directory permissions preserved" before.Unix.st_perm (Unix.lstat path).Unix.st_perm)

let test_rename_drift () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" and replacement = Filename.concat root "replacement" in
  write path "original\n";
  write replacement "replacement\n";
  let result = fold path ~f:(fun acc row -> Unix.rename replacement path; row :: acc) in
  require_error result |> check_binding_refusal (Fs.Transaction_path_binding_changed { path });
  check string "new binding never overwritten" "replacement\n" (read path);
  check (list string) "no generated metadata" ["posts.jsonl"] (entries root))

let test_unlink_drift () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  write path "original\n";
  (match require_error (fold path ~f:(fun acc row -> Unix.unlink path; row :: acc)) with
   | Unique.Operation_failed failure ->
     check bool "missing observed binding retains inspection operation" true
       (failure.operation = Fs.Inspect_transaction_path);
     (match failure.exception_ with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
      | exception_ -> fail (Printexc.to_string exception_))
   | (Unique.Non_regular_file _ | Unique.Snapshot_changed | Unique.Binding_refused _) as error ->
     fail (Unique.error_to_string error));
  check (list string) "observed disappearance never recreated" [] (entries root))

let test_link_drift () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" and alias = Filename.concat root "late-alias" in
  write path "original\n";
  require_error (fold path ~f:(fun acc row -> Unix.link path alias; row :: acc))
  |> check_binding_refusal (Fs.Ambiguous_transaction_file_identity { path; link_count = 2 });
  check string "source preserved" "original\n" (read path))

let test_content_drift ~replacement () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  write path "original\n";
  Unix.utimes path 1000. 1000.;
  let before = Unix.lstat path in
  require_error (fold path ~f:(fun acc row -> write path replacement; row :: acc))
  |> check_snapshot_changed;
  check int "same inode after in-place mutation" before.Unix.st_ino (Unix.lstat path).Unix.st_ino;
  check string "mutating actor bytes preserved" replacement (read path))

exception Primary_failure
exception Cleanup_failure

let nested_timeout () =
  Eio.Exn.Multiple [ (Primary_failure, Printexc.get_callstack 8);
                    (Eio.Time.Timeout, Printexc.get_callstack 8) ]

let test_primary_failure exception_ () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  write path "actual\n";
  let original_backtrace = ref None in
  let raise_original _ _ =
    try raise exception_ with caught ->
      let backtrace = Printexc.get_raw_backtrace () in
      original_backtrace := Some backtrace;
      Printexc.raise_with_backtrace caught backtrace
  in
  (match require_error (fold path ~f:raise_original) with
   | Unique.Operation_failed failure ->
     check bool "original primary exception identity" true (failure.exception_ == exception_);
     check bool "primary operation retained" true (failure.operation = Fs.Read_transaction_data);
     (match !original_backtrace with
      | None -> fail "actual row callback did not raise"
      | Some original ->
        let length = Printexc.raw_backtrace_length original in
        check bool "actual raising site has a backtrace" true (length > 0);
        check bool "captured trace retains original frames" true
          (Printexc.raw_backtrace_length failure.backtrace >= length);
        for index = 0 to length - 1 do
          check bool "original raw raising frame retained" true
            (Printexc.get_raw_backtrace_slot original index
             = Printexc.get_raw_backtrace_slot failure.backtrace index)
        done)
   | (Unique.Non_regular_file _ | Unique.Snapshot_changed | Unique.Binding_refused _) as error ->
     fail (Unique.error_to_string error));
  check string "primary failure does not mutate data" "actual\n" (read path))

let io_with_close_failure exception_ sync_calls close_calls : Fs.private_jsonl_transaction_io_for_testing =
  { before_sync_parent = (fun _ -> incr sync_calls)
  ; close_fd = (fun fd -> incr close_calls; Unix.close fd; raise exception_)
  }

let test_cleanup_failure exception_ () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  write path "actual\n";
  let sync_calls = ref 0 and close_calls = ref 0 in
  let io = io_with_close_failure exception_ sync_calls close_calls in
  (match Fs.fold_private_jsonl_unique_regular_locked_with_io_for_testing ~io path
           ~init:[] ~f:(fun acc row -> row :: acc) with
   | Fs.Private_file_succeeded_with_cleanup_failure
       { value = Fold.Present { value = ["actual"]; _ }; cleanup_failure } ->
     check bool "original close exception identity" true (cleanup_failure.exception_ == exception_);
     check bool "cleanup operation retained" true (cleanup_failure.operation = Fs.Close_transaction_data);
     check bool "cleanup backtrace retained" true
       (Printexc.raw_backtrace_length cleanup_failure.backtrace > 0)
   | Fs.Private_file_succeeded _ | Fs.Private_file_failed _
   | Fs.Private_file_succeeded_with_cleanup_failure _
   | Fs.Private_file_failed_with_cleanup_failure _ -> fail "close failure erased primary observation");
  check int "read never syncs a parent" 0 !sync_calls;
  check int "actual descriptor closed once" 1 !close_calls;
  check (list string) "no metadata entries" ["posts.jsonl"] (entries root);
  check string "source unchanged" "actual\n" (read path))

let test_primary_and_cleanup () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  write path "actual\n";
  let sync_calls = ref 0 and close_calls = ref 0 in
  let primary = nested_timeout () in
  let io = io_with_close_failure Cleanup_failure sync_calls close_calls in
  (match Fs.fold_private_jsonl_unique_regular_locked_with_io_for_testing ~io path
           ~init:[] ~f:(fun _ _ -> raise primary) with
   | Fs.Private_file_failed_with_cleanup_failure
       { error = Unique.Operation_failed failure; cleanup_failure } ->
     check bool "combined primary retained" true (failure.exception_ == primary);
     check bool "cleanup retained separately" true (cleanup_failure.exception_ == Cleanup_failure);
     check bool "primary backtrace retained" true (Printexc.raw_backtrace_length failure.backtrace > 0)
   | Fs.Private_file_succeeded _ | Fs.Private_file_failed _
   | Fs.Private_file_succeeded_with_cleanup_failure _
   | Fs.Private_file_failed_with_cleanup_failure _ -> fail "primary and cleanup were flattened");
  check int "read never syncs" 0 !sync_calls;
  check int "one descriptor settlement" 1 !close_calls)

let test_eio_read () = with_root (fun root ->
  let path = Filename.concat root "posts.jsonl" in
  write path "worker-row\n";
  Eio_main.run (fun env ->
    Fs.set_fs (Eio.Stdenv.fs env);
    let value, _, _ = require_present (rows path) in
    check (list string) "blocking worker returns rows" ["worker-row"] value);
  check (list string) "worker also creates no metadata" ["posts.jsonl"] (entries root))

let () =
  Printexc.record_backtrace true;
  run "fs_compat_unique_fold"
    [ "observational source",
        [ test_case "absent nested root stays absent" `Quick test_absent_root
        ; test_case "present empty is distinct from Missing" `Quick test_empty_present
        ; test_case "streaming framing preserves bytes and permissions" `Quick test_stream_framing
        ; test_case "strict alias refusal preserves existing fold policy" `Quick test_symlink_policy
        ; test_case "dangling alias is not Missing" `Quick test_dangling_symlink
        ; test_case "multiple links refuse before decoding" `Quick test_hardlink_policy
        ; test_case "nonregular descriptor refuses without metadata" `Quick test_directory_refused
        ; test_case "rename during rows refuses new binding" `Quick test_rename_drift
        ; test_case "unlink during rows never becomes Missing" `Quick test_unlink_drift
        ; test_case "new hardlink during rows refuses" `Quick test_link_drift
        ; test_case "same-inode same-length content drift refuses" `Quick
            (test_content_drift ~replacement:"changed!\n")
        ; test_case "same-inode size drift refuses" `Quick
            (test_content_drift ~replacement:"changed-and-longer\n")
        ; test_case "Eio worker uses the same observation" `Quick test_eio_read ]
    ; "descriptor settlement",
        [ test_case "ordinary primary keeps exception and backtrace" `Quick
            (test_primary_failure Primary_failure)
        ; test_case "timeout primary keeps exception and backtrace" `Quick
            (test_primary_failure Eio.Time.Timeout)
        ; test_case "allocation primary keeps exception and backtrace" `Quick
            (test_primary_failure Out_of_memory)
        ; test_case "nested reserved primary keeps whole exception" `Quick
            (test_primary_failure (nested_timeout ()))
        ; test_case "ordinary close preserves actual observation" `Quick
            (test_cleanup_failure Cleanup_failure)
        ; test_case "timeout close preserves actual observation" `Quick
            (test_cleanup_failure Eio.Time.Timeout)
        ; test_case "nested reserved close preserves observation" `Quick
            (test_cleanup_failure (nested_timeout ()))
        ; test_case "primary and cleanup remain separate" `Quick test_primary_and_cleanup ] ]
