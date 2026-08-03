module Persistence = Keeper_event_queue_persistence

let with_temp_dir prefix f =
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> f base_path)
;;

let stimulus : Keeper_event_queue.stimulus =
  { post_id = "orphan-quarantine-test"
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1.0
  ; payload = Keeper_event_queue.Bootstrap
  }
;;

let seed ~base_path ~keeper_name =
  match
    Persistence.enqueue_stimulus_if_absent_result
      ~base_path
      ~keeper_name
      stimulus
  with
  | Ok Persistence.Enqueued -> ()
  | Ok Persistence.Already_present -> Alcotest.fail "fresh queue already existed"
  | Error detail -> Alcotest.fail detail
;;

let snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.keepers_runtime_dir_of_base ~base_path)
       keeper_name)
    "event-queue-v14.json"
;;

let quarantine_root ~base_path =
  Filename.concat
    (Common.keepers_runtime_dir_of_base ~base_path)
    ".orphaned-event-queues"
;;

let quarantine_absent_owner ~base_path ~keeper_name =
  match
    Persistence.quarantine_orphaned_owner_result
      ~base_path
      ~keeper_name
      ~confirm_owner_presence:(fun () -> Ok Persistence.Orphan_owner_absent)
  with
  | Ok (Persistence.Orphan_quarantined { quarantine_path }) -> quarantine_path
  | Ok _ -> Alcotest.fail "orphan queue did not enter quarantine"
  | Error detail -> Alcotest.fail detail
;;

let test_absent_owner_moves_full_runtime_directory () =
  with_temp_dir "event-queue-orphan-quarantine-" @@ fun base_path ->
  let keeper_name = "orphan-owner" in
  seed ~base_path ~keeper_name;
  let quarantine_path = quarantine_absent_owner ~base_path ~keeper_name in
  Alcotest.(check string)
    "quarantine remains under the dedicated root"
    (quarantine_root ~base_path)
    (Filename.dirname quarantine_path);
  Alcotest.(check bool)
    "active snapshot moved"
    false
    (Sys.file_exists (snapshot_path ~base_path ~keeper_name));
  Alcotest.(check bool)
    "quarantined snapshot preserved"
    true
    (Sys.file_exists (Filename.concat quarantine_path "event-queue-v14.json"));
  Alcotest.(check (list string))
    "quarantined owner leaves discovery"
    []
    (Persistence.discover_keeper_names_with_snapshots ~base_path).keeper_names
;;

let test_reused_owner_name_gets_distinct_quarantine () =
  with_temp_dir "event-queue-reused-orphan-quarantine-" @@ fun base_path ->
  let keeper_name = "reused-orphan-owner" in
  seed ~base_path ~keeper_name;
  let first_path = quarantine_absent_owner ~base_path ~keeper_name in
  seed ~base_path ~keeper_name;
  let second_path = quarantine_absent_owner ~base_path ~keeper_name in
  Alcotest.(check bool)
    "reused owner name preserves both quarantine generations"
    true
    (not (String.equal first_path second_path));
  List.iter
    (fun path ->
       Alcotest.(check bool)
         "quarantined snapshot preserved"
         true
         (Sys.file_exists (Filename.concat path "event-queue-v14.json")))
    [ first_path; second_path ];
  Alcotest.(check bool)
    "second active snapshot moved"
    false
    (Sys.file_exists (snapshot_path ~base_path ~keeper_name))
;;

let test_reappeared_owner_fences_quarantine () =
  with_temp_dir "event-queue-owner-reappeared-" @@ fun base_path ->
  let keeper_name = "reappeared-owner" in
  seed ~base_path ~keeper_name;
  (match
     Persistence.quarantine_orphaned_owner_result
       ~base_path
       ~keeper_name
       ~confirm_owner_presence:(fun () -> Ok Persistence.Orphan_owner_present)
   with
   | Ok Persistence.Orphan_owner_reappeared -> ()
   | Ok _ -> Alcotest.fail "present owner did not fence quarantine"
   | Error detail -> Alcotest.fail detail);
  Alcotest.(check bool)
    "present owner snapshot remains active"
    true
    (Sys.file_exists (snapshot_path ~base_path ~keeper_name))
;;

let () =
  Alcotest.run
    "Keeper_event_queue_orphan_quarantine"
    [ ( "quarantine"
      , [ Alcotest.test_case
            "absent owner moves full runtime directory"
            `Quick
            test_absent_owner_moves_full_runtime_directory
        ; Alcotest.test_case
            "reappeared owner fences quarantine"
            `Quick
            test_reappeared_owner_fences_quarantine
        ; Alcotest.test_case
            "reused owner name gets a distinct quarantine"
            `Quick
            test_reused_owner_name_gets_distinct_quarantine
        ] )
    ]
;;
