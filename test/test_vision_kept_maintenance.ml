(* task-1719 / #39331 milestone B: the reference-based sweep for the kept
   vision store root. See lib/multimodal/vision_kept_maintenance.mli.

   The sweep deletes only handles that a complete reference scan found
   un-referenced in two consecutive runs. These tests pin the three
   completion criteria of #39331 -- a referenced handle survives, an
   un-referenced root file is deleted, and reading a deleted handle is a
   clean Missing_artifact rather than a crash -- plus the two rules that
   keep the sweep from deleting a live handle. *)

open Alcotest

let fresh_dir () =
  let base = Filename.temp_file "masc-vision-kept-maintenance-test-" "" in
  Sys.remove base;
  Fs_compat.mkdir_p base;
  base
;;

let write ~dir ~rel content =
  let path = Filename.concat dir rel in
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc
;;

(* Canonical 64-char lowercase-hex names: the only shape the sweep treats as
   a kept artifact. *)
let handle_a = String.make 64 'a'
let handle_b = String.make 64 'b'
let handle_c = String.make 64 'c'

let store_kept_file ~dir handle =
  write ~dir ~rel:handle (Printf.sprintf "kept-bytes-%s" handle)
;;

let mention ~masc_dir ~rel handle =
  write ~dir:masc_dir ~rel (Printf.sprintf {|{"artifact":"%s"}|} handle)
;;

let sweep ~masc_dir ~dir =
  Multimodal.Vision_kept_maintenance.run ~masc_dir ~dir
  |> Result.map_error Multimodal.Vision_kept_maintenance.error_to_string
;;

let exists ~dir handle = Sys.file_exists (Filename.concat dir handle)

let test_referenced_handle_survives () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_kept_file ~dir handle_a;
  mention ~masc_dir ~rel:"messages/turn1.json" handle_a;
  let first = sweep ~masc_dir ~dir in
  check bool "first sweep succeeds" true (Result.is_ok first);
  let second = sweep ~masc_dir ~dir in
  check bool "second sweep succeeds" true (Result.is_ok second);
  check bool "a referenced kept file is never deleted" true (exists ~dir handle_a);
  match second with
  | Ok report ->
    check int "the referenced handle counts as live" 1 report.live;
    check int "nothing is deleted" 0 report.deleted
  | Error _ -> ()
;;

let test_unreferenced_handle_is_deleted () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_kept_file ~dir handle_b;
  let first = sweep ~masc_dir ~dir in
  check bool "first sweep records without deleting" true
    (match first with Ok r -> r.deleted = 0 | Error _ -> false);
  check bool "the candidate is still present after one sweep" true
    (exists ~dir handle_b);
  let second = sweep ~masc_dir ~dir in
  check bool "second sweep succeeds" true (Result.is_ok second);
  check bool "an un-referenced kept file is deleted on the second sweep" false
    (exists ~dir handle_b);
  match second with
  | Ok report -> check int "one handle deleted" 1 report.deleted
  | Error _ -> ()
;;

let test_deleted_handle_reads_as_missing () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_kept_file ~dir handle_c;
  ignore (sweep ~masc_dir ~dir);
  ignore (sweep ~masc_dir ~dir);
  check bool "the file is gone" false (exists ~dir handle_c);
  match
    Multimodal.Vision_artifact_store.load ~dir
      (Multimodal.Vision_artifact_store.of_string handle_c)
  with
  | Error (Multimodal.Vision_artifact_store.Missing_artifact _) -> ()
  | Error other ->
    failwith
      ("expected Missing_artifact, got: "
       ^ Multimodal.Vision_artifact_store.load_error_to_string other)
  | Ok _ -> failwith "a deleted handle must not read as present"
;;

(* The two-pass rule is what keeps a handle that is only briefly
   un-referenced -- a turn restored from an older checkpoint, a write whose
   referencing turn has not flushed yet -- from being deleted. *)
let test_reappearing_reference_is_not_deleted () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_kept_file ~dir handle_a;
  ignore (sweep ~masc_dir ~dir);
  (* run 1: handle_a is a candidate *)
  mention ~masc_dir ~rel:"messages/turn2.json" handle_a;
  (* the reference appears before the next sweep *)
  let second = sweep ~masc_dir ~dir in
  check bool "second sweep succeeds" true (Result.is_ok second);
  check bool "a handle referenced again before the second sweep survives" true
    (exists ~dir handle_a)
;;

(* An unknown is not a candidate: a symlink at the kept root aborts the
   sweep before anything is deleted. *)
let test_symlink_aborts_the_sweep () =
  let masc_dir = fresh_dir () in
  let dir = fresh_dir () in
  store_kept_file ~dir handle_a;
  Unix.symlink (fresh_dir ()) (Filename.concat dir handle_b);
  match sweep ~masc_dir ~dir with
  | Error _ -> ()
  | Ok _ -> failwith "a symlink at the kept root must abort the sweep"
;;

(* A symlink used as the store root must not send deletion into its target,
   even when that target contains only canonical, unreferenced handles. *)
let test_symlinked_store_root_keeps_external_files () =
  let masc_dir = fresh_dir () in
  let keepers_dir = fresh_dir () in
  let outside = fresh_dir () in
  let dir = Filename.concat keepers_dir "fixture.vision" in
  store_kept_file ~dir:outside handle_a;
  Unix.symlink outside dir;
  for _ = 1 to 2 do
    (match Multimodal.Vision_kept_maintenance.run ~masc_dir ~dir with
     | Error (Multimodal.Vision_kept_maintenance.Invalid_store_root rejected) ->
       check string "error names the symlinked store" dir rejected.dir;
       check string "error identifies the symlink" "symlinked store root" rejected.detail
     | Error other ->
       fail (Multimodal.Vision_kept_maintenance.error_to_string other)
     | Ok _ -> fail "a symlinked store root must abort before deletion")
  done;
  check bool "external kept file is untouched" true (exists ~dir:outside handle_a);
  check bool "no candidate snapshot is written outside" false
    (Sys.file_exists (Filename.concat outside "kept-candidates.json"))
;;

let () =
  run
    "vision_kept_maintenance"
    [ ( "sweep"
      , [ test_case "referenced handle survives" `Quick test_referenced_handle_survives
        ; test_case
            "un-referenced handle is deleted"
            `Quick
            test_unreferenced_handle_is_deleted
        ; test_case
            "deleted handle reads as missing"
            `Quick
            test_deleted_handle_reads_as_missing
        ; test_case
            "reappearing reference is not deleted"
            `Quick
            test_reappearing_reference_is_not_deleted
        ; test_case "symlink aborts the sweep" `Quick test_symlink_aborts_the_sweep
        ; test_case "symlinked store root stays outside the sweep" `Quick
            test_symlinked_store_root_keeps_external_files
        ] )
    ]
;;
