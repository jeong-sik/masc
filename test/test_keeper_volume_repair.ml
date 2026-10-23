open Alcotest
open Masc
module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch
module Repair = Keeper_volume_repair

(* RFC keeper-volume-filesystem-repair §3.3: the repair flow with every
   effect faked, so each outcome shows which effects ran and in what order. *)

let damaged = Fs.Errors_recorded { count = 3; first = None; last = None }
let image = "/images/work.img"
let backup = Repair.backup_path ~image
let work = { Watch.name = "masc-keeper-work-k"; kind = Watch.Work }
let build = { Watch.name = "masc-keeper-build-k"; kind = Watch.Build }

let finished ?(cleanup = Ok ()) ?(stderr = "") status stdout =
  Ok { Repair.status; stdout; stderr; cleanup }
;;

type plan =
  { volume : Watch.volume
  ; helper_image : bool
  ; backup_exists : bool
  ; teardown : (unit, string) result
  ; reads : (Fs.state, Fs.read_failure) result list
  ; clone : (unit, string) result
  ; helper : (Repair.helper_finished, string) result
  }

let repairable =
  { volume = work
  ; helper_image = true
  ; backup_exists = false
  ; teardown = Ok ()
  ; reads = [ Ok damaged; Ok Fs.Clean ]
  ; clone = Ok ()
  ; helper = finished (Unix.WEXITED 0) "e2fsck repair exit 1\ne2fsck verify exit 0"
  }
;;

let run_plan plan =
  let events = ref [] in
  let note event = events := event :: !events in
  let reads = ref plan.reads in
  let read_image ~path =
    note ("read " ^ path);
    match !reads with
    | next :: rest ->
      reads := rest;
      next
    | [] -> fail "read_image called more often than the case planned"
  in
  let helper =
    if plan.helper_image
    then
      Ok
        (fun () ->
          note "helper";
          plan.helper)
    else Error "catalog unreadable"
  in
  let receipt =
    Repair.repair
      ~now:(fun () -> 0.)
      ~repair_id:"repair-1"
      ~helper
      ~backup_exists:(fun ~path ->
        note ("backup? " ^ path);
        plan.backup_exists)
      ~teardown:(fun () ->
        note "teardown";
        plan.teardown)
      ~read_image
      ~clone:(fun ~source ~target ->
        note (Printf.sprintf "clone %s %s" source target);
        plan.clone)
      ~keeper:"k"
      ~volume:plan.volume
      ~image
  in
  receipt, List.rev !events
;;

let kind (receipt : Repair.receipt) =
  Yojson.Safe.Util.(Repair.outcome_to_yojson receipt.outcome |> member "kind" |> to_string)
;;

let through_teardown = [ "backup? " ^ backup; "teardown"; "read " ^ image ]
let through_clone = through_teardown @ [ Printf.sprintf "clone %s %s" image backup ]
let through_helper = through_clone @ [ "helper" ]
let read_after = through_helper @ [ "read " ^ image ]

let check_run name plan ~kind:expected_kind ~events:expected_events ~backup:expected_backup =
  let receipt, events = run_plan plan in
  check string (name ^ ": outcome") expected_kind (kind receipt);
  check (list string) (name ^ ": effects") expected_events events;
  check (option string) (name ^ ": backup") expected_backup receipt.backup;
  receipt
;;

let test_a_damaged_volume_is_repaired () =
  let receipt =
    check_run "repaired" repairable ~kind:"repaired" ~events:read_after ~backup:(Some backup)
  in
  check bool "the read after teardown is kept" true (receipt.before = Some (Ok damaged));
  check (option string) "helper status" (Some "exit=0") receipt.helper_status;
  check (option string) "helper removed" None receipt.helper_cleanup
;;

let test_nothing_runs_without_a_helper_image () =
  let receipt =
    check_run
      "no helper image"
      { repairable with helper_image = false }
      ~kind:"helper_unavailable"
      ~events:[]
      ~backup:None
  in
  check bool "no read" true (receipt.before = None)
;;

(* The backup is the operator's: an existing one stops the repair before the
   guests are removed, so a failed repair can never replace the original. *)
let test_an_existing_backup_stops_before_teardown () =
  ignore
    (check_run
       "backup present"
       { repairable with backup_exists = true }
       ~kind:"backup_present"
       ~events:[ "backup? " ^ backup ]
       ~backup:None
     : Repair.receipt)
;;

let test_a_refused_teardown_reads_nothing () =
  ignore
    (check_run
       "teardown refused"
       { repairable with teardown = Error "guest still running" }
       ~kind:"teardown_refused"
       ~events:[ "backup? " ^ backup; "teardown" ]
       ~backup:None
     : Repair.receipt)
;;

(* The sweep can read a superblock the guest is half-way through writing;
   the read with no guest attached decides. *)
let test_a_clean_read_after_teardown_needs_nothing () =
  ignore
    (check_run
       "not needed"
       { repairable with reads = [ Ok Fs.Clean ] }
       ~kind:"not_needed"
       ~events:through_teardown
       ~backup:None
     : Repair.receipt)
;;

let test_an_unreadable_image_is_not_cloned () =
  ignore
    (check_run
       "unreadable before"
       { repairable with reads = [ Error (Fs.Unreadable "gone") ] }
       ~kind:"unreadable_before"
       ~events:through_teardown
       ~backup:None
     : Repair.receipt)
;;

let test_a_failed_clone_runs_no_helper () =
  ignore
    (check_run
       "backup unavailable"
       { repairable with clone = Error "Operation not supported" }
       ~kind:"backup_unavailable"
       ~events:through_clone
       ~backup:None
     : Repair.receipt)
;;

(* A helper that never started wrote nothing, so there is nothing to read. *)
let test_a_helper_that_cannot_start_keeps_the_backup () =
  ignore
    (check_run
       "helper error"
       { repairable with helper = Error "stale helper not removed" }
       ~kind:"helper_refused"
       ~events:through_helper
       ~backup:(Some backup)
     : Repair.receipt)
;;

(* Once the helper ran it may have written the image, whatever its status:
   the superblock is read again in every case below. *)
let test_a_failed_helper_with_errors_left_is_refused () =
  let receipt =
    check_run
      "helper exit 1"
      { repairable with
        reads = [ Ok damaged; Ok damaged ]
      ; helper =
          finished ~stderr:"volume is still mounted; e2fsck not run" (Unix.WEXITED 1) ""
      }
      ~kind:"helper_refused"
      ~events:read_after
      ~backup:(Some backup)
  in
  check (option string) "helper status" (Some "exit=1") receipt.helper_status
;;

let test_a_stopped_helper_with_a_clean_superblock_repaired () =
  ignore
    (check_run
       "stopped after e2fsck"
       { repairable with helper = finished (Unix.WSIGNALED 15) "e2fsck repair exit 1" }
       ~kind:"repaired"
       ~events:read_after
       ~backup:(Some backup)
     : Repair.receipt)
;;

let test_errors_left_after_e2fsck_are_incomplete () =
  ignore
    (check_run
       "repair incomplete"
       { repairable with reads = [ Ok damaged; Ok damaged ] }
       ~kind:"repair_incomplete"
       ~events:read_after
       ~backup:(Some backup)
     : Repair.receipt)
;;

let test_an_unreadable_result_is_unconfirmed () =
  ignore
    (check_run
       "unreadable after"
       { repairable with reads = [ Ok damaged; Error (Fs.Truncated { bytes = 0 }) ] }
       ~kind:"unreadable_after"
       ~events:read_after
       ~backup:(Some backup)
     : Repair.receipt)
;;

(* A helper that could not be removed after it ran does not hide what
   e2fsck did. *)
let test_a_failed_cleanup_keeps_the_result () =
  let receipt =
    check_run
      "cleanup failed"
      { repairable with
        helper =
          finished
            ~cleanup:(Error "container list timed out")
            (Unix.WEXITED 0)
            "e2fsck repair exit 1"
      }
      ~kind:"repaired"
      ~events:read_after
      ~backup:(Some backup)
  in
  check (option string) "cleanup failure kept" (Some "container list timed out") receipt.helper_cleanup;
  check bool "output kept" true (receipt.helper_output <> None)
;;

(* The next fresh boot deletes and recreates a build volume, so removing the
   guests is the whole repair: no backup, clone or helper. *)
let test_a_build_volume_is_left_for_the_next_boot () =
  ignore
    (check_run
       "build volume"
       { repairable with volume = build }
       ~kind:"recreated_at_next_boot"
       ~events:[ "teardown" ]
       ~backup:None
     : Repair.receipt);
  ignore
    (check_run
       "build volume teardown refused"
       { repairable with volume = build; teardown = Error "guest still running" }
       ~kind:"teardown_refused"
       ~events:[ "teardown" ]
       ~backup:None
     : Repair.receipt)
;;

let test_the_receipt_keeps_the_helper_output () =
  let stdout = String.concat "\n" (List.init 4000 (Printf.sprintf "Entry %d moved to lost+found")) in
  let receipt, _ =
    run_plan
      { repairable with helper = finished ~stderr:"warning on stderr" (Unix.WEXITED 0) stdout }
  in
  let json = Repair.receipt_to_yojson receipt in
  let open Yojson.Safe.Util in
  check string "schema" "masc.keeper.volume_repair.v1" (json |> member "schema" |> to_string);
  check string "volume kind" "work" (json |> member "volume_kind" |> to_string);
  check
    string
    "stdout and stderr"
    (stdout ^ "\nwarning on stderr")
    (json |> member "helper_output" |> to_string);
  let stopped, _ = run_plan { repairable with backup_exists = true } in
  check bool "no read is null" true (Repair.receipt_to_yojson stopped |> member "before" = `Null)
;;

let test_receipts_are_kept_per_keeper () =
  let path keeper = Repair.receipt_path ~masc_dir:"/m" ~keeper ~repair_id:"repair-1" in
  check string "file name" "repair-1.json" (Filename.basename (path "k"));
  check
    string
    "store directory"
    "/m/keeper-volume-repairs"
    (Filename.dirname (Filename.dirname (path "k")));
  check bool "one directory per keeper" true (Filename.dirname (path "a") <> Filename.dirname (path "b"))
;;

let with_temp_dir f =
  let dir = Filename.temp_dir "keeper-volume-repair" "" in
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Sys.rmdir path
    | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
      Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove dir) (fun () -> f dir)
;;

let test_a_written_receipt_reads_back () =
  Eio_main.run
  @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir (fun masc_dir ->
    let receipt, _ = run_plan repairable in
    match Repair.write_receipt ~masc_dir receipt with
    | Error detail -> failf "receipt not written: %s" detail
    | Ok path ->
      check string "at its path" (Repair.receipt_path ~masc_dir ~keeper:"k" ~repair_id:"repair-1") path;
      check
        string
        "same JSON"
        (Yojson.Safe.to_string (Repair.receipt_to_yojson receipt))
        (Yojson.Safe.to_string (Yojson.Safe.from_file path)))
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path contents =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel contents)
;;

(* clonefile(2) exists only on macOS. Either the clone is a separate file
   with the same bytes, or nothing is created: never a data copy. *)
let test_a_clone_is_a_clone_or_nothing () =
  with_temp_dir (fun dir ->
    let source = Filename.concat dir "volume.img" in
    let target = Repair.backup_path ~image:source in
    write_file source "superblock bytes";
    match Repair.clone_image ~source ~target with
    | Ok () ->
      check string "same bytes" "superblock bytes" (read_file target);
      write_file target "changed";
      check string "the source is untouched" "superblock bytes" (read_file source)
    | Error _ -> check bool "no file was created" false (Sys.file_exists target))
;;

let test_a_clone_never_replaces_a_file () =
  with_temp_dir (fun dir ->
    let source = Filename.concat dir "volume.img" in
    let target = Repair.backup_path ~image:source in
    write_file source "new image";
    write_file target "first backup";
    (match Repair.clone_image ~source ~target with
     | Ok () -> fail "a clone replaced an existing backup"
     | Error _ -> ());
    check string "the first backup is kept" "first backup" (read_file target))
;;

(* A clone of a link would be a second link to the image e2fsck is about to
   change, not a backup of it. *)
let test_a_symlinked_image_is_not_cloned () =
  with_temp_dir (fun dir ->
    let real = Filename.concat dir "real.img" in
    let link = Filename.concat dir "volume.img" in
    let target = Repair.backup_path ~image:link in
    write_file real "image bytes";
    Unix.symlink real link;
    (match Repair.clone_image ~source:link ~target with
     | Ok () -> fail "a symlink was cloned as a backup"
     | Error _ -> ());
    check bool "no backup was created" false (Sys.file_exists target))
;;

let () =
  run
    "keeper_volume_repair"
    [ ( "repair"
      , [ test_case "damaged volume repaired" `Quick test_a_damaged_volume_is_repaired
        ; test_case "no helper image" `Quick test_nothing_runs_without_a_helper_image
        ; test_case "existing backup stops first" `Quick test_an_existing_backup_stops_before_teardown
        ; test_case "teardown refused" `Quick test_a_refused_teardown_reads_nothing
        ; test_case "clean after teardown" `Quick test_a_clean_read_after_teardown_needs_nothing
        ; test_case "unreadable before" `Quick test_an_unreadable_image_is_not_cloned
        ; test_case "failed clone" `Quick test_a_failed_clone_runs_no_helper
        ; test_case "helper cannot start" `Quick test_a_helper_that_cannot_start_keeps_the_backup
        ; test_case "helper fails, errors left" `Quick test_a_failed_helper_with_errors_left_is_refused
        ; test_case "helper stopped, superblock clean" `Quick
            test_a_stopped_helper_with_a_clean_superblock_repaired
        ; test_case "errors left" `Quick test_errors_left_after_e2fsck_are_incomplete
        ; test_case "unreadable after" `Quick test_an_unreadable_result_is_unconfirmed
        ; test_case "failed cleanup keeps the result" `Quick test_a_failed_cleanup_keeps_the_result
        ; test_case "build volume left for next boot" `Quick test_a_build_volume_is_left_for_the_next_boot
        ] )
    ; ( "receipt"
      , [ test_case "helper output" `Quick test_the_receipt_keeps_the_helper_output
        ; test_case "per keeper" `Quick test_receipts_are_kept_per_keeper
        ; test_case "written and read back" `Quick test_a_written_receipt_reads_back
        ] )
    ; ( "clone"
      , [ test_case "clone or nothing" `Quick test_a_clone_is_a_clone_or_nothing
        ; test_case "never replaces" `Quick test_a_clone_never_replaces_a_file
        ; test_case "symlinked image refused" `Quick test_a_symlinked_image_is_not_cloned
        ] )
    ]
;;
