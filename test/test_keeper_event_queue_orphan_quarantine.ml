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

let make_keeper_meta ?(paused = false) ?(name = "sangsu")
    ?(trace_id = "trace-sangsu-live")
    ?(updated_at = "2026-03-29T10:36:57Z") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("agent_name", `String ("keeper-" ^ name ^ "-agent"))
        ; ("trace_id", `String trace_id)
        ; ("updated_at", `String updated_at)
        ])
  with
  | Ok meta -> { meta with paused }
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
;;

let write_keeper_meta_exn config meta =
  match Keeper_meta_store.write_meta config meta with
  | Ok () -> ()
  | Error err -> Alcotest.fail ("keeper meta write failed: " ^ err)
;;

let write_basepath_keeper_toml base_path name =
  let keepers_dir =
    Filename.concat
      (Filename.concat (Filename.concat base_path Common.masc_dirname) "config")
      "keepers"
  in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
instructions = "example"
proactive_enabled = false
autoboot_enabled = true
|}
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

let test_owner_reappearing_after_rename_restores_runtime () =
  with_temp_dir "event-queue-owner-reappeared-after-rename-" @@ fun base_path ->
  let keeper_name = "reappeared-after-rename" in
  let confirmation_count = ref 0 in
  seed ~base_path ~keeper_name;
  (match
     Persistence.quarantine_orphaned_owner_result
       ~base_path
       ~keeper_name
       ~confirm_owner_presence:(fun () ->
         incr confirmation_count;
         Ok
           (if !confirmation_count = 1
            then Persistence.Orphan_owner_absent
            else Persistence.Orphan_owner_present))
   with
   | Ok Persistence.Orphan_owner_reappeared -> ()
   | Ok _ -> Alcotest.fail "owner appearing after rename was not restored"
   | Error detail -> Alcotest.fail detail);
  Alcotest.(check int) "owner authority checked twice" 2 !confirmation_count;
  Alcotest.(check bool)
    "reappeared owner snapshot restored"
    true
    (Sys.file_exists (snapshot_path ~base_path ~keeper_name));
  Alcotest.(check (list string))
    "restored owner leaves no quarantined generation"
    []
    (Array.to_list (Sys.readdir (quarantine_root ~base_path)))
;;

let test_exact_owner_presence_requires_exact_authority () =
  with_temp_dir "durable-queue-owner-presence-" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let module Recovery = Server_bootstrap_maintenance.Recovery_for_testing in
  let presence keeper_name =
    match Recovery.exact_owner_presence config keeper_name with
    | Ok presence -> presence
    | Error detail -> Alcotest.fail detail
  in
  (match presence "absent-owner" with
   | Recovery.Owner_absent -> ()
   | _ -> Alcotest.fail "owner without exact authority was retained");
  write_basepath_keeper_toml base_path "declared-owner";
  (match presence "declared-owner" with
   | Recovery.Owner_not_materialized -> ()
   | _ -> Alcotest.fail "exact TOML owner was classified as orphaned");
  let persisted_meta =
    make_keeper_meta
      ~name:"persisted-owner"
      ~trace_id:"trace-persisted-owner"
      ()
  in
  write_keeper_meta_exn config persisted_meta;
  (match presence persisted_meta.name with
   | Recovery.Owner_present -> ()
   | _ -> Alcotest.fail "exact persisted owner was not authoritative");
  let registered_meta =
    make_keeper_meta
      ~name:"registered-owner"
      ~trace_id:"trace-registered-owner"
      ()
  in
  ignore
    (Keeper_registry.For_testing.register
       ~base_path
       registered_meta.name
       registered_meta);
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.unregister ~base_path registered_meta.name)
    (fun () ->
      match presence registered_meta.name with
      | Recovery.Owner_present -> ()
      | _ -> Alcotest.fail "exact registered owner was not authoritative")
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
            "owner reappearing after rename restores runtime"
            `Quick
            test_owner_reappearing_after_rename_restores_runtime
        ; Alcotest.test_case
            "reused owner name gets a distinct quarantine"
            `Quick
            test_reused_owner_name_gets_distinct_quarantine
        ; Alcotest.test_case
            "exact owner presence requires exact authority"
            `Quick
            test_exact_owner_presence_requires_exact_authority
        ] )
    ]
;;
