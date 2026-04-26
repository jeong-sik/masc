(* test/test_fs_atomic_orphan_sweep_10130.ml

   #10130: [.atomic_*.tmp] orphans from [save_file_atomic]
   accumulate after SIGKILL or ENFILE because the OCaml
   with-handler never ran.  The 2026-04-24 audit found 33
   orphans with 6 non-zero files holding real keeper-meta
   JSON — evidence of 6 silent data-loss events.

   [Fs_compat.cleanup_atomic_orphans] is a boot-time sweep:
   - zero-byte orphans are deleted;
   - non-zero orphans are MOVED (not deleted) to
     [<base_path>/.recovered/] so operators can forensically
     inspect data-loss events.

   These tests pin that contract so a future refactor can't
   silently delete the forensic evidence.
*)

let make_temp_base () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-fs-atomic-10130-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let rm_rf path =
  let rec go p =
    match Unix.lstat p with
    | exception Unix.Unix_error _ -> ()
    | { st_kind = S_DIR; _ } ->
      Array.iter (fun e -> go (Filename.concat p e)) (Sys.readdir p);
      (try Unix.rmdir p with
       | Unix.Unix_error _ -> ())
    | _ ->
      (try Unix.unlink p with
       | Unix.Unix_error _ -> ())
  in
  go path
;;

let with_temp_base f =
  let dir = make_temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let write_file ~path ~content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let touch path = write_file ~path ~content:""

(* Name matcher is strict: both prefix and suffix required. *)
let test_name_matcher () =
  let yes s =
    Alcotest.(check bool) ("match " ^ s) true (Fs_compat.is_atomic_orphan_name s)
  in
  let no s =
    Alcotest.(check bool) ("no match " ^ s) false (Fs_compat.is_atomic_orphan_name s)
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
;;

(* Zero-byte orphans at base_path: deleted, counter reports
   [(1, 0)]. *)
let test_zero_byte_orphan_at_base_deleted () =
  with_temp_base
  @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_empty01.tmp" in
  touch orphan;
  let deleted, preserved = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check int) "1 deleted" 1 deleted;
  Alcotest.(check int) "0 preserved" 0 preserved;
  Alcotest.(check bool) "orphan file removed" false (Sys.file_exists orphan)
;;

(* Non-zero orphan at base_path: moved to .recovered/, NOT
   deleted.  The original path is gone but the payload survives
   in the recovered directory for forensic inspection. *)
let test_nonzero_orphan_preserved_in_recovered () =
  with_temp_base
  @@ fun base_path ->
  let orphan = Filename.concat base_path ".atomic_data42.tmp" in
  let payload = "{\"name\":\"sangsu\",\"goal\":\"…\"}" in
  write_file ~path:orphan ~content:payload;
  let deleted, preserved = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check int) "0 deleted" 0 deleted;
  Alcotest.(check int) "1 preserved" 1 preserved;
  Alcotest.(check bool) "original removed" false (Sys.file_exists orphan);
  let recovered_dir = Filename.concat base_path ".recovered" in
  Alcotest.(check bool) ".recovered/ created" true (Sys.file_exists recovered_dir);
  let entries = Sys.readdir recovered_dir in
  Alcotest.(check int) "1 file in .recovered/" 1 (Array.length entries);
  let recovered_path = Filename.concat recovered_dir entries.(0) in
  let ic = open_in recovered_path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  Alcotest.(check string) "payload survived" payload content
;;

(* Orphans in subdirs are found too.  #10130 evidence was mostly
   under base_path/keepers/. *)
let test_orphans_in_subdirs_found () =
  with_temp_base
  @@ fun base_path ->
  let subdir = Filename.concat base_path "keepers" in
  Unix.mkdir subdir 0o755;
  touch (Filename.concat subdir ".atomic_zeroKeeper.tmp");
  write_file
    ~path:(Filename.concat subdir ".atomic_dataKeeper.tmp")
    ~content:"sangsu data";
  let deleted, preserved = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check int) "1 deleted from subdir" 1 deleted;
  Alcotest.(check int) "1 preserved from subdir" 1 preserved
;;

(* Non-orphan files must NOT be touched.  Matches the
   [is_atomic_orphan_name] predicate strictly. *)
let test_non_orphan_files_untouched () =
  with_temp_base
  @@ fun base_path ->
  let normal = Filename.concat base_path "sangsu.json" in
  write_file ~path:normal ~content:"{\"real\":\"data\"}";
  let atomic_no_suffix = Filename.concat base_path ".atomic_abc" in
  write_file ~path:atomic_no_suffix ~content:"not an orphan";
  let _ = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check bool) "sangsu.json survived" true (Sys.file_exists normal);
  Alcotest.(check bool)
    ".atomic_abc (no .tmp) survived"
    true
    (Sys.file_exists atomic_no_suffix)
;;

(* Idempotent: second call on an already-clean dir is a noop. *)
let test_idempotent () =
  with_temp_base
  @@ fun base_path ->
  touch (Filename.concat base_path ".atomic_once.tmp");
  let _ = Fs_compat.cleanup_atomic_orphans ~base_path () in
  let deleted, preserved = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check int) "second call: 0 deleted" 0 deleted;
  Alcotest.(check int) "second call: 0 preserved" 0 preserved
;;

(* Mixed case (matches the 2026-04-24 production evidence:
   33 orphans total, 6 with data). *)
let test_mixed_batch () =
  with_temp_base
  @@ fun base_path ->
  (* 10 empty + 3 with data *)
  for i = 0 to 9 do
    touch (Filename.concat base_path (Printf.sprintf ".atomic_empty%02d.tmp" i))
  done;
  for i = 0 to 2 do
    write_file
      ~path:(Filename.concat base_path (Printf.sprintf ".atomic_data%02d.tmp" i))
      ~content:(Printf.sprintf "payload %d" i)
  done;
  let deleted, preserved = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check int) "10 deleted" 10 deleted;
  Alcotest.(check int) "3 preserved" 3 preserved
;;

(* .recovered/ dir itself must be skipped on recursion so we
   don't loop on any orphan someone moved there by hand. *)
let test_recovered_dir_skipped_on_rescan () =
  with_temp_base
  @@ fun base_path ->
  let recovered = Filename.concat base_path ".recovered" in
  Unix.mkdir recovered 0o755;
  (* Drop an orphan-shaped name into .recovered/ directly.  A
     rescan must not touch it. *)
  write_file
    ~path:(Filename.concat recovered ".atomic_seed.tmp")
    ~content:"already forensic";
  let deleted, preserved = Fs_compat.cleanup_atomic_orphans ~base_path () in
  Alcotest.(check int) "0 deleted" 0 deleted;
  Alcotest.(check int) "0 preserved (recovered/ not re-scanned)" 0 preserved;
  Alcotest.(check bool)
    ".recovered/ seed file untouched"
    true
    (Sys.file_exists (Filename.concat recovered ".atomic_seed.tmp"))
;;

let () =
  Alcotest.run
    "fs_atomic_orphan_sweep_10130"
    [ ( "name-matcher"
      , [ Alcotest.test_case "strict prefix+suffix match" `Quick test_name_matcher ] )
    ; ( "sweep-behavior"
      , [ Alcotest.test_case
            "zero-byte at base: deleted"
            `Quick
            test_zero_byte_orphan_at_base_deleted
        ; Alcotest.test_case
            "non-zero: preserved in .recovered/"
            `Quick
            test_nonzero_orphan_preserved_in_recovered
        ; Alcotest.test_case
            "orphans in subdirs found"
            `Quick
            test_orphans_in_subdirs_found
        ; Alcotest.test_case
            "non-orphan files untouched"
            `Quick
            test_non_orphan_files_untouched
        ; Alcotest.test_case "idempotent: second call is noop" `Quick test_idempotent
        ; Alcotest.test_case "mixed batch (prod-shaped)" `Quick test_mixed_batch
        ; Alcotest.test_case
            ".recovered/ skipped on rescan"
            `Quick
            test_recovered_dir_skipped_on_rescan
        ] )
    ]
;;
