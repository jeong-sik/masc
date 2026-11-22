(* test/test_fs_atomic_orphan_sweep_10130.ml

   #10130: [.atomic_*.tmp] orphans from [save_file_atomic]
   accumulate after SIGKILL or ENFILE because the OCaml
   with-handler never ran.  The 2026-04-24 audit found 33
   orphans with 6 non-zero files holding real keeper-meta
   JSON — evidence of 6 silent data-loss events.

   [Fs_compat.cleanup_atomic_orphans] is a boot-time sweep:
   - zero-byte orphans are deleted;
   - non-zero orphans are MOVED (not deleted) to
     [<base_path>/.recovered/root/] so operators can forensically
     inspect data-loss events.

   These tests pin that contract so a future refactor can't
   silently delete the forensic evidence.
*)

let make_temp_base () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-fs-atomic-10130-%06x"
         (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  dir

let rm_rf path =
  let rec go p =
    match Unix.lstat p with
    | exception Unix.Unix_error _ -> ()
    | { st_kind = S_DIR; _ } ->
        (Array.iter (fun e -> go (Filename.concat p e)) (Sys.readdir p));
        (try Unix.rmdir p with Unix.Unix_error _ -> ())
    | _ -> (try Unix.unlink p with Unix.Unix_error _ -> ())
  in
  go path

let with_temp_base f =
  let dir = make_temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file ~path ~content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let touch path = write_file ~path ~content:""

let cleanup ?ownership_root base_path =
  let ownership_root = Option.value ownership_root ~default:base_path in
  Fs_compat.cleanup_atomic_orphans ~ownership_root ~base_path ()

let check_no_failures report =
  match report.Fs_compat.failures with
  | [] -> ()
  | failures ->
    Alcotest.fail
      (String.concat
         "\n"
         (List.map Fs_compat.atomic_orphan_cleanup_failure_to_string failures))
;;

(* Name matcher is strict: both prefix and suffix required. *)
let test_name_matcher () =
  let yes s =
    Alcotest.(check bool) ("match " ^ s) true
      (Fs_compat.is_atomic_orphan_name s)
  in
  let no s =
    Alcotest.(check bool) ("no match " ^ s) false
      (Fs_compat.is_atomic_orphan_name s)
  in
  yes ".atomic_abc.tmp";
  yes ".atomic_946c84.tmp";
  yes ".atomic_.tmp";
  yes ".private_jsonl_a1b2c3.stage";
  yes ".private_jsonl_.stage";
  no ".private_jsonl_prep_a1b2c3.prep";
  no ".private_jsonl_prep_.prep";
  no "atomic_abc.tmp";
  no ".atomic_abc";
  no ".private_jsonl_abc";
  no "private_jsonl_abc.stage";
  no "normal.json";
  no "alpha.json";
  no ".atomic_prefix_only";
  no "prefix_.atomic_abc.tmp" (* prefix not at start *)

(* Zero-byte orphans at base_path: deleted, counter reports
   [(1, 0)]. *)
let test_zero_byte_orphan_at_base_deleted () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_empty01.tmp" in
  touch orphan;
  let report = cleanup base_path in
  check_no_failures report;
  Alcotest.(check int) "1 inspected" 1 report.inspected;
  Alcotest.(check int) "1 deleted" 1 report.deleted;
  Alcotest.(check int) "0 preserved" 0 report.preserved;
  Alcotest.(check bool) "orphan file removed" false
    (Sys.file_exists orphan)

(* Non-zero orphan at base_path: moved to .recovered/, NOT
   deleted.  The original path is gone but the payload survives
   in the recovered directory for forensic inspection. *)
let test_nonzero_orphan_preserved_in_recovered () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_data42.tmp" in
  let payload = "{\"name\":\"alpha\",\"goal\":\"…\"}" in
  write_file ~path:orphan ~content:payload;
  let report = cleanup base_path in
  check_no_failures report;
  Alcotest.(check int) "0 deleted" 0 report.deleted;
  Alcotest.(check int) "1 preserved" 1 report.preserved;
  Alcotest.(check bool) "original removed" false
    (Sys.file_exists orphan);
  let recovered_dir = Filename.concat base_path ".recovered" in
  Alcotest.(check bool) ".recovered/ created" true
    (Sys.file_exists recovered_dir);
  let recovered_root = Filename.concat recovered_dir "root" in
  let entries = Sys.readdir recovered_root in
  Alcotest.(check int) "1 file in .recovered/root/" 1 (Array.length entries);
  let recovered_path = Filename.concat recovered_root entries.(0) in
  let ic = open_in recovered_path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  Alcotest.(check string) "payload survived"
    payload content

(* Non-orphan files must NOT be touched.  Matches the
   [is_atomic_orphan_name] predicate strictly. *)
let test_non_orphan_files_untouched () =
  with_temp_base @@ fun base_path ->
  let normal = Filename.concat base_path "alpha.json" in
  write_file ~path:normal ~content:"{\"real\":\"data\"}";
  let atomic_no_suffix = Filename.concat base_path ".atomic_abc" in
  write_file ~path:atomic_no_suffix ~content:"not an orphan";
  let report = cleanup base_path in
  check_no_failures report;
  Alcotest.(check bool) "alpha.json survived" true
    (Sys.file_exists normal);
  Alcotest.(check bool) ".atomic_abc (no .tmp) survived" true
    (Sys.file_exists atomic_no_suffix)

(* Idempotent: second call on an already-clean dir is a noop. *)
let test_idempotent () =
  with_temp_base @@ fun base_path ->
  touch (Filename.concat base_path ".atomic_once.tmp");
  let first = cleanup base_path in
  check_no_failures first;
  let second = cleanup base_path in
  check_no_failures second;
  Alcotest.(check int) "second call: 0 deleted" 0 second.deleted;
  Alcotest.(check int) "second call: 0 preserved" 0 second.preserved

(* Mixed case (matches the 2026-04-24 production evidence:
   33 orphans total, 6 with data). *)
let test_mixed_batch () =
  with_temp_base @@ fun base_path ->
  (* 10 empty + 3 with data *)
  for i = 0 to 9 do
    touch (Filename.concat base_path
             (Printf.sprintf ".atomic_empty%02d.tmp" i))
  done;
  for i = 0 to 2 do
    write_file
      ~path:(Filename.concat base_path
               (Printf.sprintf ".atomic_data%02d.tmp" i))
      ~content:(Printf.sprintf "payload %d" i)
  done;
  let report = cleanup base_path in
  check_no_failures report;
  Alcotest.(check int) "13 inspected" 13 report.inspected;
  Alcotest.(check int) "10 deleted" 10 report.deleted;
  Alcotest.(check int) "3 preserved" 3 report.preserved

let test_symlink_ancestor_is_rejected () =
  with_temp_base @@ fun ownership_root ->
  with_temp_base @@ fun outside ->
  let outside_scan = Filename.concat outside "scan" in
  Unix.mkdir outside_scan 0o755;
  let outside_orphan = Filename.concat outside_scan ".atomic_external.tmp" in
  write_file ~path:outside_orphan ~content:"outside";
  let linked = Filename.concat ownership_root "linked" in
  Unix.symlink outside linked;
  let scan_root = Filename.concat linked "scan" in
  let report = cleanup ~ownership_root scan_root in
  Alcotest.(check int) "nothing inspected outside boundary" 0 report.inspected;
  Alcotest.(check bool) "typed ancestor failure" true (report.failures <> []);
  Alcotest.(check bool) "external orphan untouched" true
    (Sys.file_exists outside_orphan)

let test_symlink_recovery_directory_is_rejected () =
  with_temp_base @@ fun base_path ->
  with_temp_base @@ fun outside ->
  let orphan = Filename.concat base_path ".atomic_evidence.tmp" in
  write_file ~path:orphan ~content:"evidence";
  Unix.symlink outside (Filename.concat base_path ".recovered");
  let report = cleanup base_path in
  Alcotest.(check int) "not preserved outside boundary" 0 report.preserved;
  Alcotest.(check bool) "typed cleanup failure" true
    (report.failures <> []);
  Alcotest.(check bool) "source evidence retained" true
    (Sys.file_exists orphan);
  Alcotest.(check int) "outside remains empty" 0
    (Array.length (Sys.readdir outside))

let test_orphan_shaped_non_regular_entry_is_rejected () =
  with_temp_base @@ fun base_path ->
  let orphan_dir = Filename.concat base_path ".atomic_directory.tmp" in
  Unix.mkdir orphan_dir 0o755;
  let report = cleanup base_path in
  Alcotest.(check int) "non-regular entry untouched" 0 report.deleted;
  Alcotest.(check bool) "typed kind failure" true (report.failures <> []);
  Alcotest.(check bool) "directory retained" true (Sys.file_exists orphan_dir)

let test_preservation_never_overwrites_existing_evidence () =
  with_temp_base @@ fun base_path ->
  let recovered_root = Filename.concat base_path ".recovered/root" in
  Unix.mkdir (Filename.concat base_path ".recovered") 0o755;
  Unix.mkdir recovered_root 0o755;
  let name = ".atomic_collision.tmp" in
  write_file ~path:(Filename.concat recovered_root name) ~content:"older";
  write_file ~path:(Filename.concat base_path name) ~content:"newer";
  let report = cleanup base_path in
  check_no_failures report;
  Alcotest.(check int) "new evidence preserved" 1 report.preserved;
  let entries = Sys.readdir recovered_root |> Array.to_list in
  Alcotest.(check int) "both evidence files retained" 2 (List.length entries);
  let contents =
    List.map
      (fun entry ->
         let path = Filename.concat recovered_root entry in
         let ic = open_in path in
         Fun.protect
           ~finally:(fun () -> close_in_noerr ic)
           (fun () -> really_input_string ic (in_channel_length ic)))
      entries
    |> List.sort String.compare
  in
  Alcotest.(check (list string)) "no overwrite" [ "newer"; "older" ] contents

let test_recovery_creation_failure_is_reported () =
  with_temp_base @@ fun base_path ->
  write_file ~path:(Filename.concat base_path ".recovered") ~content:"occupied";
  let orphan = Filename.concat base_path ".atomic_evidence.tmp" in
  write_file ~path:orphan ~content:"evidence";
  let report = cleanup base_path in
  Alcotest.(check int) "not falsely preserved" 0 report.preserved;
  Alcotest.(check bool) "failure surfaced" true (report.failures <> []);
  Alcotest.(check bool) "source retained" true (Sys.file_exists orphan)

let test_private_jsonl_stage_reclaims_stranded_and_skips_active () =
  with_temp_base @@ fun base_path ->
  let empty_stage = Filename.concat base_path ".private_jsonl_empty01.stage" in
  let data_stage = Filename.concat base_path ".private_jsonl_data01.stage" in
  let active_stage = Filename.concat base_path ".private_jsonl_live01.stage" in
  touch empty_stage;
  write_file ~path:data_stage ~content:"{\"row\":1}\n";
  write_file ~path:active_stage ~content:"{\"in_flight\":true}\n";
  let active_fd =
    Unix.openfile active_stage [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600
  in
  let locked = Fs_compat.try_lock_stage_fd_for_testing active_fd in
  Alcotest.(check bool) "stage flock acquired" true locked;
  let first =
    Fun.protect
      ~finally:(fun () -> Unix.close active_fd)
      (fun () ->
         let report = cleanup base_path in
         check_no_failures report;
         Alcotest.(check bool) "active stage skipped while locked" true
           (Sys.file_exists active_stage);
         report)
  in
  Alcotest.(check int) "2 stranded stages inspected" 2 first.inspected;
  Alcotest.(check int) "1 empty stage deleted" 1 first.deleted;
  Alcotest.(check int) "1 nonempty stage preserved" 1 first.preserved;
  Alcotest.(check bool) "empty stage removed" false (Sys.file_exists empty_stage);
  Alcotest.(check bool) "data stage moved" false (Sys.file_exists data_stage);
  let second = cleanup base_path in
  check_no_failures second;
  Alcotest.(check int) "released stage reclaimed on next sweep" 1 second.preserved;
  Alcotest.(check bool) "released stage moved" false (Sys.file_exists active_stage)

let test_failing_sync_parent_does_not_double_close_reused_fd () =
  with_temp_base @@ fun base_path ->
  let target = Filename.concat base_path "published.json" in
  let sentinel = Filename.concat base_path "sentinel.txt" in
  write_file ~path:sentinel ~content:"keep-open";
  let opened_in_sync = ref None in
  let outcome =
    Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_file:(fun _ -> ())
      ~sync_parent:(fun _ ->
        (* Opening a fresh FD immediately after [close_lock_fd] reclaims the
           just-closed numeric FD slot on POSIX. A double [Unix.close lock_fd]
           in the exception handler would silently close [fd]. *)
        let fd = Unix.openfile sentinel [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
        opened_in_sync := Some fd;
        raise (Unix.Unix_error (Unix.EIO, "fsync", "parent")))
      target
      "{\"ok\":true}\n"
  in
  (match outcome with
   | Ok () -> Alcotest.fail "expected After_rename sync_parent failure"
   | Error failure ->
     Alcotest.(check bool) "failure stage is After_rename" true
       (failure.stage = Fs_compat.After_rename));
  match !opened_in_sync with
  | None -> Alcotest.fail "sync_parent was not called"
  | Some fd ->
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
         let st = Unix.fstat fd in
         Alcotest.(check bool) "reused fd stayed open after failing sync_parent" true
           (st.Unix.st_kind = Unix.S_REG && st.Unix.st_size = String.length "keep-open"))

let test_missing_recovery_grand_parent_reports_enoent_not_identity_changed () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_missing_grand.tmp" in
  write_file ~path:orphan ~content:"evidence";
  let missing_grand = Filename.concat base_path "missing-grand" in
  let recovery_parent = Filename.concat missing_grand "recovery-parent" in
  let report =
    Fs_compat.cleanup_atomic_orphans
      ~recovery_parent
      ~ownership_root:base_path
      ~base_path
      ()
  in
  Alcotest.(check int) "orphan not preserved when grand_parent missing" 0 report.preserved;
  Alcotest.(check bool) "source orphan retained" true (Sys.file_exists orphan);
  let has_enoent =
    List.exists
      (fun (f : Fs_compat.atomic_orphan_cleanup_failure) ->
         f.operation = Fs_compat.Create_recovery_directory
         && String.equal f.path missing_grand
         &&
         match f.cause with
         | Fs_compat.Unix_failure (Unix.ENOENT, _, _) -> true
         | Fs_compat.Unix_failure _
         | Fs_compat.Sys_failure _
         | Fs_compat.Unexpected_file_kind _
         | Fs_compat.Outside_ownership_root _
         | Fs_compat.Identity_changed
         | Fs_compat.Other_failure _ -> false)
      report.failures
  in
  Alcotest.(check bool) "missing grand_parent reports Unix ENOENT (not Identity_changed)" true
    has_enoent

let () =
  Alcotest.run "fs_atomic_orphan_sweep_10130"
    [
      ( "name-matcher",
        [ Alcotest.test_case "strict prefix+suffix match" `Quick
            test_name_matcher ] );
      ( "sweep-behavior",
        [
          Alcotest.test_case "zero-byte at base: deleted" `Quick
            test_zero_byte_orphan_at_base_deleted;
          Alcotest.test_case "non-zero: preserved in .recovered/" `Quick
            test_nonzero_orphan_preserved_in_recovered;
          Alcotest.test_case "non-orphan files untouched" `Quick
            test_non_orphan_files_untouched;
          Alcotest.test_case "idempotent: second call is noop" `Quick
            test_idempotent;
          Alcotest.test_case "mixed batch (prod-shaped)" `Quick
            test_mixed_batch;
          Alcotest.test_case "symlink ancestor is rejected" `Quick
            test_symlink_ancestor_is_rejected;
          Alcotest.test_case "symlink recovery directory rejected" `Quick
            test_symlink_recovery_directory_is_rejected;
          Alcotest.test_case "non-regular orphan rejected" `Quick
            test_orphan_shaped_non_regular_entry_is_rejected;
          Alcotest.test_case "preservation never overwrites" `Quick
            test_preservation_never_overwrites_existing_evidence;
          Alcotest.test_case "recovery creation failure surfaced" `Quick
            test_recovery_creation_failure_is_reported;
          Alcotest.test_case "private_jsonl stage stranded vs active" `Quick
            test_private_jsonl_stage_reclaims_stranded_and_skips_active;
          Alcotest.test_case "failing sync_parent never double-closes reused fd" `Quick
            test_failing_sync_parent_does_not_double_close_reused_fd;
          Alcotest.test_case "missing recovery grand_parent reports ENOENT" `Quick
            test_missing_recovery_grand_parent_reports_enoent_not_identity_changed;
        ] );
    ]
