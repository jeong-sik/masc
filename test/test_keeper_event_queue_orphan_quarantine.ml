module Persistence = Keeper_event_queue_persistence

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
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

let quarantine_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.keepers_runtime_dir_of_base ~base_path)
       ".orphaned-event-queues")
    keeper_name
;;

let test_absent_owner_moves_full_runtime_directory () =
  with_temp_dir "event-queue-orphan-quarantine-" @@ fun base_path ->
  let keeper_name = "orphan-owner" in
  seed ~base_path ~keeper_name;
  let quarantine_path = quarantine_path ~base_path ~keeper_name in
  (match
     Persistence.quarantine_orphaned_owner_result
       ~base_path
       ~keeper_name
       ~confirm_owner_presence:(fun () -> Ok Persistence.Orphan_owner_absent)
   with
   | Ok (Persistence.Orphan_quarantined result) ->
     Alcotest.(check string)
       "typed quarantine path"
       quarantine_path
       result.quarantine_path
   | Ok _ -> Alcotest.fail "orphan queue did not enter quarantine"
   | Error detail -> Alcotest.fail detail);
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
        ] )
    ]
;;
