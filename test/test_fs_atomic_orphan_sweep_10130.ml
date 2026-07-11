(* test/test_fs_atomic_orphan_sweep_10130.ml

   #10130: [.atomic_*.tmp] orphans from [save_file_atomic]
   accumulate after SIGKILL or ENFILE because the OCaml
   with-handler never ran.  The 2026-04-24 audit found 33
   orphans with 6 non-zero files holding real keeper-meta
   JSON — evidence of 6 silent data-loss events.

   [Fs_compat.cleanup_atomic_orphans] is a boot-time sweep:
   - zero-byte orphans are deleted;
   - non-zero orphans are MOVED (not deleted) to
     a source-directory bucket below [<base_path>/.recovered/] so operators can
     forensically
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
  no "atomic_abc.tmp";
  no ".atomic_abc";
  no "normal.json";
  no "sangsu.json";
  no ".atomic_prefix_only";
  no "prefix_.atomic_abc.tmp" (* prefix not at start *)

(* Zero-byte orphans at base_path: deleted, counter reports
   [(1, 0)]. *)
let test_zero_byte_orphan_at_base_deleted () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_empty01.tmp" in
  touch orphan;
  let deleted, preserved =
    Fs_compat.cleanup_atomic_orphans ~base_path ()
  in
  Alcotest.(check int) "1 deleted" 1 deleted;
  Alcotest.(check int) "0 preserved" 0 preserved;
  Alcotest.(check bool) "orphan file removed" false
    (Sys.file_exists orphan)

(* Non-zero orphan at base_path: moved to .recovered/, NOT
   deleted.  The original path is gone but the payload survives
   in the recovered directory for forensic inspection. *)
let test_nonzero_orphan_preserved_in_recovered () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_data42.tmp" in
  let payload = "{\"name\":\"sangsu\",\"goal\":\"…\"}" in
  write_file ~path:orphan ~content:payload;
  let deleted, preserved =
    Fs_compat.cleanup_atomic_orphans ~base_path ()
  in
  Alcotest.(check int) "0 deleted" 0 deleted;
  Alcotest.(check int) "1 preserved" 1 preserved;
  Alcotest.(check bool) "original removed" false
    (Sys.file_exists orphan);
  let recovered_root = Filename.concat base_path ".recovered" in
  let recovered_dir = Filename.concat recovered_root "root" in
  Alcotest.(check bool) ".recovered/root created" true
    (Sys.file_exists recovered_dir);
  let entries = Sys.readdir recovered_dir in
  Alcotest.(check int) "1 file in .recovered/" 1 (Array.length entries);
  let recovered_path = Filename.concat recovered_dir entries.(0) in
  let ic = open_in recovered_path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  Alcotest.(check string) "payload survived"
    payload content

(* Orphans in subdirs are found too.  #10130 evidence was mostly
   under base_path/keepers/. *)
let test_orphans_in_subdirs_found () =
  with_temp_base @@ fun base_path ->
  let subdir = Filename.concat base_path "keepers" in
  Unix.mkdir subdir 0o755;
  touch (Filename.concat subdir ".atomic_zeroKeeper.tmp");
  write_file ~path:(Filename.concat subdir ".atomic_dataKeeper.tmp")
    ~content:"sangsu data";
  let deleted, preserved =
    Fs_compat.cleanup_atomic_orphans ~base_path ()
  in
  Alcotest.(check int) "1 deleted from subdir" 1 deleted;
  Alcotest.(check int) "1 preserved from subdir" 1 preserved

(* Non-orphan files must NOT be touched.  Matches the
   [is_atomic_orphan_name] predicate strictly. *)
let test_non_orphan_files_untouched () =
  with_temp_base @@ fun base_path ->
  let normal = Filename.concat base_path "sangsu.json" in
  write_file ~path:normal ~content:"{\"real\":\"data\"}";
  let atomic_no_suffix = Filename.concat base_path ".atomic_abc" in
  write_file ~path:atomic_no_suffix ~content:"not an orphan";
  let _ = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check bool) "sangsu.json survived" true
    (Sys.file_exists normal);
  Alcotest.(check bool) ".atomic_abc (no .tmp) survived" true
    (Sys.file_exists atomic_no_suffix)

(* Idempotent: second call on an already-clean dir is a noop. *)
let test_idempotent () =
  with_temp_base @@ fun base_path ->
  touch (Filename.concat base_path ".atomic_once.tmp");
  let _ = Fs_compat.cleanup_atomic_orphans ~base_path () in
  let deleted, preserved =
    Fs_compat.cleanup_atomic_orphans ~base_path ()
  in
  Alcotest.(check int) "second call: 0 deleted" 0 deleted;
  Alcotest.(check int) "second call: 0 preserved" 0 preserved

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
  let deleted, preserved =
    Fs_compat.cleanup_atomic_orphans ~base_path ()
  in
  Alcotest.(check int) "10 deleted" 10 deleted;
  Alcotest.(check int) "3 preserved" 3 preserved

(* .recovered/ dir itself must be skipped on recursion so we
   don't loop on any orphan someone moved there by hand. *)
let test_recovered_dir_skipped_on_rescan () =
  with_temp_base @@ fun base_path ->
  let recovered = Filename.concat base_path ".recovered" in
  Unix.mkdir recovered 0o755;
  (* Drop an orphan-shaped name into .recovered/ directly.  A
     rescan must not touch it. *)
  write_file ~path:(Filename.concat recovered ".atomic_seed.tmp")
    ~content:"already forensic";
  let deleted, preserved =
    Fs_compat.cleanup_atomic_orphans ~base_path ()
  in
  Alcotest.(check int) "0 deleted" 0 deleted;
  Alcotest.(check int) "0 preserved (recovered/ not re-scanned)"
    0 preserved;
  Alcotest.(check bool) ".recovered/ seed file untouched" true
    (Sys.file_exists (Filename.concat recovered ".atomic_seed.tmp"))

let test_direct_recovery_rejects_symlinked_destination () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_data.tmp" in
  let target = Filename.concat base_path "outside" in
  let recovered = Filename.concat base_path "recovered" in
  write_file ~path:orphan ~content:"forensic payload";
  Unix.mkdir target 0o755;
  Unix.symlink target recovered;
  (match
     Fs_compat.recover_atomic_orphan
       ~path:orphan
       ~recovered_root:recovered
       ~bucket:"root"
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "symlinked recovery destination was accepted");
  Alcotest.(check bool) "orphan retained" true (Sys.file_exists orphan);
  Alcotest.(check int)
    "symlink target untouched"
    0
    (Array.length (Sys.readdir target))

let test_direct_recovery_rejects_symlinked_source () =
  with_temp_base @@ fun base_path ->
  let target = Filename.concat base_path "target" in
  let orphan = Filename.concat base_path ".atomic_symlink.tmp" in
  let recovered_root = Filename.concat base_path "recovered" in
  let recovered = Filename.concat recovered_root "root" in
  write_file ~path:target ~content:"must remain outside recovery";
  Unix.mkdir recovered_root 0o755;
  Unix.mkdir recovered 0o755;
  Unix.symlink target orphan;
  (match
     Fs_compat.recover_atomic_orphan
       ~path:orphan
       ~recovered_root
       ~bucket:"root"
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "symlinked orphan source was accepted");
  Alcotest.(check bool) "source symlink retained" true (Sys.file_exists orphan);
  Alcotest.(check string)
    "symlink target retained"
    "must remain outside recovery"
    (Fs_compat.load_file_unix target)

let test_cleanup_rejects_recovery_escape () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_data.tmp" in
  write_file ~path:orphan ~content:"forensic payload";
  (match
     Fs_compat.cleanup_atomic_orphans
       ~base_path
       ~recovered_subdir:"../outside"
       ()
   with
   | exception Invalid_argument _ -> ()
   | _ -> Alcotest.fail "recovery traversal was accepted");
  Alcotest.(check bool) "traversal source retained" true (Sys.file_exists orphan)

let test_cleanup_rejects_symlinked_recovery_root () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_data.tmp" in
  let target = Filename.concat base_path "outside" in
  let recovered = Filename.concat base_path ".recovered" in
  write_file ~path:orphan ~content:"forensic payload";
  Unix.mkdir target 0o755;
  Unix.symlink target recovered;
  let deleted, preserved = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check int) "no deletion through symlink" 0 deleted;
  Alcotest.(check int) "no preservation through symlink" 0 preserved;
  Alcotest.(check bool) "symlink source retained" true (Sys.file_exists orphan);
  Alcotest.(check int)
    "symlink root target untouched"
    0
    (Array.length (Sys.readdir target))

let test_direct_recovery_preserves_without_overwrite () =
  with_temp_base @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_data.tmp" in
  let recovered_root = Filename.concat base_path "recovered" in
  let recovered = Filename.concat recovered_root "root" in
  Unix.mkdir recovered_root 0o755;
  Unix.mkdir recovered 0o755;
  write_file ~path:orphan ~content:"first";
  let destination = Filename.concat recovered ".atomic_data.tmp" in
  (match
     Fs_compat.recover_atomic_orphan
       ~path:orphan
       ~recovered_root
       ~bucket:"root"
   with
   | Ok (Fs_compat.Preserved_nonempty actual) ->
     Alcotest.(check string) "recovery destination" destination actual
   | Ok Fs_compat.Deleted_zero_length -> Alcotest.fail "nonempty orphan deleted"
   | Error detail -> Alcotest.failf "direct recovery failed: %s" detail);
  write_file ~path:orphan ~content:"second";
  (match
     Fs_compat.recover_atomic_orphan
       ~path:orphan
       ~recovered_root
       ~bucket:"root"
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "existing forensic evidence was overwritten");
  Alcotest.(check bool) "second orphan retained" true (Sys.file_exists orphan);
  Unix.unlink destination;
  Unix.link orphan destination;
  (match
     Fs_compat.recover_atomic_orphan
       ~path:orphan
       ~recovered_root
       ~bucket:"root"
   with
   | Ok (Fs_compat.Preserved_nonempty actual) ->
     Alcotest.(check string) "interrupted recovery destination" destination actual
   | Ok Fs_compat.Deleted_zero_length -> Alcotest.fail "linked orphan deleted"
   | Error detail -> Alcotest.failf "linked recovery failed: %s" detail);
  Alcotest.(check bool)
    "interrupted source acknowledged"
    false
    (Sys.file_exists orphan)

let test_blocking_durable_primitives () =
  with_temp_base @@ fun base_path ->
  let nested = Filename.concat base_path "one/two/three" in
  Fs_compat.mkdir_p_durable_unix nested;
  Alcotest.(check bool) "durable directory tree created" true (Sys.is_directory nested);
  let target = Filename.concat nested "state.json" in
  (match Fs_compat.save_file_atomic_unix target "first" with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "blocking atomic write failed: %s" detail);
  (match Fs_compat.save_file_atomic_unix target "second" with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "blocking atomic overwrite failed: %s" detail);
  let content = Fs_compat.load_file_unix target in
  Alcotest.(check string) "blocking atomic content" "second" content;
  let append_target = Filename.concat nested "events.jsonl" in
  Fs_compat.append_file_durable append_target "one\n";
  Fs_compat.append_file_durable append_target "two\n";
  let appended = Fs_compat.load_file_unix append_target in
  Alcotest.(check string) "durable append content" "one\ntwo\n" appended;
  let missing_parent_target =
    Filename.concat base_path "missing-parent/state.json"
  in
  (match Fs_compat.save_file_atomic_unix missing_parent_target "value" with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "write with missing parent unexpectedly succeeded");
  (match Fs_compat.fsync_directory target with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "regular file accepted as directory fsync target")

let test_durable_mkdir_rejects_non_directories () =
  with_temp_base @@ fun base_path ->
  let file = Filename.concat base_path "file" in
  let target = Filename.concat base_path "target" in
  let symlink = Filename.concat base_path "symlink" in
  write_file ~path:file ~content:"not a directory";
  Unix.mkdir target 0o755;
  Unix.symlink target symlink;
  (match Fs_compat.mkdir_p_durable_unix file with
   | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> ()
   | _ -> Alcotest.fail "regular file accepted as durable directory");
  (match Fs_compat.mkdir_p_durable_unix (Filename.concat symlink "child") with
   | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> ()
   | _ -> Alcotest.fail "symlinked ancestor accepted as durable directory");
  Alcotest.(check int)
    "symlink target unchanged"
    0
    (Array.length (Sys.readdir target))

let test_durable_append_falls_back_outside_eio () =
  with_temp_base @@ fun base_path ->
  Fun.protect
    ~finally:Fs_compat.clear_fs
    (fun () ->
       Eio_main.run (fun env -> Fs_compat.set_fs (Eio.Stdenv.fs env));
       let path = Filename.concat base_path "outside-eio.jsonl" in
       Fs_compat.append_file_durable path "row\n";
       Alcotest.(check string)
         "fallback durable append"
         "row\n"
         (Fs_compat.load_file_unix path))

let anchored_segment raw =
  match Fs_compat.Anchored_dir.Segment.of_string raw with
  | Ok segment -> segment
  | Error error ->
    Alcotest.failf
      "invalid anchored test segment %S: %s"
      raw
      (Fs_compat.Anchored_dir.Segment.error_to_string error)
;;

let require_anchored_mutation label = function
  | Ok value -> value
  | Error error ->
    Alcotest.failf
      "%s: %s"
      label
      (Fs_compat.Anchored_dir.mutation_error_to_string error)
;;

let test_anchored_directory_primitives () =
  with_temp_base @@ fun base_path ->
  let module Dir = Fs_compat.Anchored_dir in
  Dir.with_open_root base_path @@ fun root ->
  Dir.with_ensure_dir
    root
    ~name:(anchored_segment "managed")
    ~perm:0o700
    ~enforce_perm:true
  @@ fun managed ->
  require_anchored_mutation
    "anchored atomic write"
    (Dir.atomic_replace
       managed
       ~name:(anchored_segment "state.json")
       ~perm:0o600
       "one");
  Alcotest.(check string)
    "anchored read"
    "one"
    (Dir.read_file managed (anchored_segment "state.json"));
  (match Dir.stat managed (anchored_segment "state.json") with
   | Some { kind = Dir.Regular_file; _ } -> ()
   | Some _ -> Alcotest.fail "anchored stat returned the wrong file kind"
   | None -> Alcotest.fail "anchored stat lost a committed file");
  require_anchored_mutation
    "anchored rename"
    (Dir.rename
       ~src_dir:managed
       ~src:(anchored_segment "state.json")
       ~dst_dir:managed
       ~dst:(anchored_segment "renamed.json"));
  Alcotest.(check bool)
    "source removed by rename"
    false
    (Option.is_some (Dir.stat managed (anchored_segment "state.json")));
  Alcotest.(check bool)
    "renamed file removed"
    true
    (match
       require_anchored_mutation
         "anchored unlink"
         (Dir.unlink_if_exists managed (anchored_segment "renamed.json"))
     with
     | `Removed -> true
     | `Missing -> false);
  Alcotest.(check bool)
    "missing unlink is explicit false"
    false
    (match
       require_anchored_mutation
         "anchored missing unlink"
         (Dir.unlink_if_exists managed (anchored_segment "renamed.json"))
     with
     | `Removed -> true
     | `Missing -> false)

let test_anchored_capability_survives_path_substitution () =
  with_temp_base @@ fun base_path ->
  let module Dir = Fs_compat.Anchored_dir in
  let managed_path = Filename.concat base_path "managed" in
  let detached_path = Filename.concat base_path "detached" in
  let outside_path = Filename.concat base_path "outside" in
  Unix.mkdir managed_path 0o700;
  Unix.mkdir outside_path 0o700;
  Dir.with_open_root base_path @@ fun root ->
  Dir.with_open_dir root (anchored_segment "managed") @@ fun managed ->
  Unix.rename managed_path detached_path;
  Unix.symlink outside_path managed_path;
  require_anchored_mutation
    "anchored write after substitution"
    (Dir.atomic_replace
       managed
       ~name:(anchored_segment "proof.json")
       ~perm:0o600
       "anchored");
  Alcotest.(check bool)
    "replacement symlink target untouched"
    false
    (Sys.file_exists (Filename.concat outside_path "proof.json"));
  Alcotest.(check string)
    "open descriptor retained original directory"
    "anchored"
    (Fs_compat.load_file_unix (Filename.concat detached_path "proof.json"))

let test_anchored_root_rejects_symlink () =
  with_temp_base @@ fun base_path ->
  let module Dir = Fs_compat.Anchored_dir in
  let target = Filename.concat base_path "target" in
  let alias = Filename.concat base_path "alias" in
  Unix.mkdir target 0o700;
  Unix.symlink target alias;
  match Dir.with_open_root alias (fun _ -> ()) with
  | exception Unix.Unix_error _ -> ()
  | () -> Alcotest.fail "symlinked root was accepted as an anchored capability"

let test_anchored_segments_reject_ambiguous_names () =
  let module Segment = Fs_compat.Anchored_dir.Segment in
  List.iter
    (fun raw ->
       match Segment.of_string raw with
       | Error _ -> ()
       | Ok _ -> Alcotest.failf "ambiguous anchored segment accepted: %S" raw)
    [ ""; "."; ".."; "a/b"; "nul\000suffix" ]

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
          Alcotest.test_case "orphans in subdirs found" `Quick
            test_orphans_in_subdirs_found;
          Alcotest.test_case "non-orphan files untouched" `Quick
            test_non_orphan_files_untouched;
          Alcotest.test_case "idempotent: second call is noop" `Quick
            test_idempotent;
          Alcotest.test_case "mixed batch (prod-shaped)" `Quick
            test_mixed_batch;
          Alcotest.test_case ".recovered/ skipped on rescan" `Quick
            test_recovered_dir_skipped_on_rescan;
          Alcotest.test_case "symlinked recovery rejected" `Quick
            test_direct_recovery_rejects_symlinked_destination;
          Alcotest.test_case "symlinked source rejected" `Quick
            test_direct_recovery_rejects_symlinked_source;
          Alcotest.test_case "recovery traversal rejected" `Quick
            test_cleanup_rejects_recovery_escape;
          Alcotest.test_case "symlinked recovery root rejected" `Quick
            test_cleanup_rejects_symlinked_recovery_root;
          Alcotest.test_case "direct recovery does not overwrite" `Quick
            test_direct_recovery_preserves_without_overwrite;
        ] );
      ( "durable-primitives",
        [ Alcotest.test_case "blocking durable filesystem boundaries" `Quick
            test_blocking_durable_primitives;
          Alcotest.test_case "durable mkdir rejects non-directories" `Quick
            test_durable_mkdir_rejects_non_directories;
          Alcotest.test_case "durable append outside Eio runtime" `Quick
            test_durable_append_falls_back_outside_eio;
          Alcotest.test_case "descriptor anchored operations" `Quick
            test_anchored_directory_primitives;
          Alcotest.test_case "ancestor substitution stays confined" `Quick
            test_anchored_capability_survives_path_substitution;
          Alcotest.test_case "symlinked root rejected" `Quick
            test_anchored_root_rejects_symlink;
          Alcotest.test_case "ambiguous segments rejected" `Quick
            test_anchored_segments_reject_ambiguous_names;
        ] );
    ]
