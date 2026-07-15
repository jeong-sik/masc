open Alcotest

module Recovery = Fs_compat.Publication_recovery

let with_tmp_dir f =
  let path = Filename.temp_file "masc_publication_reconcile_" ".tmp" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let operation_id value =
  match Uuidm.of_string value with
  | Some operation_id -> operation_id
  | None -> failf "invalid test UUID %S" value
;;

let with_registry ~fs ~registry_root f =
  Eio.Switch.run @@ fun sw ->
  match
    Recovery.open_registry
      ~sw
      ~fs
      ~registry_root:Eio.Path.(fs / registry_root)
  with
  | Ok registry -> f registry
  | Error error -> fail (Recovery.transition_error_to_string error)
;;

let require_fixture = function
  | Ok () -> ()
  | Error error ->
    fail (Fs_compat.publication_recovery_fixture_error_to_string error)
;;

let seed_prepared
      ~registry
      ~owner
      ~operation_id
      ~allowed_root_path
      ~allowed_root_device
      ~allowed_root_inode
  =
  Fs_compat.Capability_write_for_testing.seed_prepared_publication_recovery
    ~registry
    ~owner
    ~operation_id
    ~allowed_root_path
    ~allowed_root_device
    ~allowed_root_inode
    ~parent_components:[]
    ~parent_device:allowed_root_device
    ~parent_inode:allowed_root_inode
    ~target_leaf:"target.json"
    ~permissions:0o600
  |> require_fixture
;;

let discover_owner registry expected_name =
  let rows =
    match Recovery.discover_owners registry with
    | Ok rows -> rows
    | Error error -> fail (Recovery.discovery_error_to_string error)
  in
  match
    List.filter_map
      (function
        | Recovery.Discovered_owner owner
          when String.equal (Recovery.owner_to_string owner) expected_name ->
          Some owner
        | Recovery.Discovered_owner _
        | Recovery.Invalid_owner_name _ -> None)
      rows
  with
  | [ owner ] -> owner
  | owners ->
    failf
      "expected exactly one discovered owner %S, got %d"
      expected_name
      (List.length owners)
;;

let inspect_valid ~registry ~owner =
  match Recovery.inspect_owner ~registry ~owner with
  | Ok (Recovery.Valid_owner valid_owner) -> valid_owner
  | Ok row ->
    failf
      "expected valid exact owner inspection, got %s"
      (Recovery.owner_inventory_row_to_string row)
  | Error error -> fail (Recovery.inspection_error_to_string error)
;;

let with_lane_ok registry owner =
  match Recovery.with_lane ~registry ~owner (fun _ -> ()) with
  | Ok (Recovery.Lane_released ()) -> ()
  | Ok (Recovery.Lane_release_failed _) ->
    fail "publication recovery lane release failed"
  | Error error -> fail (Recovery.lane_open_error_to_string error)
;;

let snapshot_owner_name = function
  | Recovery.Snapshot_owner_inventory_pending owner
  | Recovery.Snapshot_owner_inventory_running owner
  | Recovery.Snapshot_owner_reconciliation_pending owner
  | Recovery.Snapshot_owner_reconciliation_running owner
  | Recovery.Snapshot_owner_ready_without_obligation owner
  | Recovery.Snapshot_owner_ready (owner, _)
  | Recovery.Snapshot_owner_blocked (owner, _) -> Recovery.owner_to_string owner
;;

let find_owner_snapshot registry owner_name =
  let snapshot = Recovery.For_testing.snapshot registry in
  List.find_opt
    (fun owner -> String.equal (snapshot_owner_name owner) owner_name)
    snapshot.owners
;;

let inventory_owner registry expected_name =
  let owner = discover_owner registry expected_name in
  inspect_valid ~registry ~owner
;;

let reconcile ~fs:_ registry owner =
  match Recovery.reconcile_owner ~registry ~owner with
  | Ok report -> report
  | Error error -> fail (Recovery.reconciliation_error_to_string error)
;;

let report_kinds =
  Fs_compat.publication_recovery_reconciliation_report_row_kinds
;;

let report_ready = Recovery.report_is_ready

let report_text =
  Fs_compat.publication_recovery_reconciliation_report_to_string
;;

(* Tests pin the durable layout for fault injection only. Production traversal
   remains capability-relative and never reconstructs these paths. *)
let owner_lane_path ~registry_root ~owner =
  List.fold_left
    Filename.concat
    registry_root
    [ "fs-publication-recovery"; "lanes"; owner ]
;;

let owner_area_path ~registry_root ~owner area =
  Filename.concat (owner_lane_path ~registry_root ~owner) area
;;

let report_has_kind expected report =
  List.exists (( = ) expected) (report_kinds report)
;;

let test_prepared_absent_becomes_forensic () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "prepared-absent" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "11111111-1111-4111-8111-111111111111")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "ready" true (report_ready report);
  (match report_kinds report with
   | [ Fs_compat.Publication_recovery_prepared_reconciled
         Fs_compat.Publication_recovery_prepared_unmaterialized ] -> ()
   | _ -> fail (report_text report));
  with_lane_ok registry owner_name
;;

let test_bound_stage_is_preserved () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root_path = Eio.Path.(fs / allowed_root_path) in
  let root = Eio.Path.stat ~follow:false root_path in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "bound-stage" in
  let operation_id = operation_id "22222222-2222-4222-8222-222222222222" in
  let stage_name =
    Fs_compat.Capability_write_for_testing.publication_recovery_stage_name
      operation_id
  in
  let stage_path = Eio.Path.(root_path / stage_name) in
  Eio.Path.mkdir ~perm:0o700 stage_path;
  let stage = Eio.Path.stat ~follow:false stage_path in
  let target_file = Filename.concat allowed_root_path "target.json" in
  let target_content = "operator-owned-target-sentinel" in
  Out_channel.with_open_bin target_file (fun channel ->
    Out_channel.output_string channel target_content);
  let target_path = Eio.Path.(root_path / "target.json") in
  let target_before = Eio.Path.stat ~follow:false target_path in
  with_registry ~fs ~registry_root @@ fun registry ->
  Fs_compat.Capability_write_for_testing.seed_bound_publication_recovery
    ~registry
    ~owner:owner_name
    ~operation_id
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino
    ~parent_components:[]
    ~parent_device:root.dev
    ~parent_inode:root.ino
    ~target_leaf:"target.json"
    ~permissions:0o600
    ~stage_device:stage.dev
    ~stage_inode:stage.ino
  |> require_fixture;
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "ready" true (report_ready report);
  (match report_kinds report with
   | [ Fs_compat.Publication_recovery_bound_reconciled
         Fs_compat.Publication_recovery_bound_stage_preserved ] -> ()
   | _ -> fail (report_text report));
  check bool "stage remains in target parent" true (Eio.Path.is_directory stage_path);
  let target_after = Eio.Path.stat ~follow:false target_path in
  check int64 "target device unchanged" target_before.dev target_after.dev;
  check int64 "target inode unchanged" target_before.ino target_after.ino;
  check string
    "target content unchanged"
    target_content
    (In_channel.with_open_bin target_file In_channel.input_all)
;;

let test_allowed_root_identity_mismatch_is_forensic () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "root-mismatch" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "33333333-3333-4333-8333-333333333333")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:Int64.(add root.ino 1L);
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "mismatch source resolved" true (report_ready report);
  match report_kinds report with
  | [ Fs_compat.Publication_recovery_prepared_reconciled
        Fs_compat.Publication_recovery_prepared_allowed_root_mismatch ] -> ()
  | _ -> fail (report_text report)
;;

let write_raw ~registry ~owner ~area ~record_name raw =
  Fs_compat.Capability_write_for_testing.write_raw_publication_recovery_record
    ~registry
    ~owner
    ~area
    ~record_name
    ~raw
  |> require_fixture
;;

let test_corrupt_and_invalid_rows_block_only_owner () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "corrupt-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_active
    ~record_name:"44444444-4444-4444-8444-444444444444"
    "{not-json";
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_active
    ~record_name:"not-a-canonical-uuid"
    "foreign";
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "blocked" false (report_ready report);
  check bool
    "corrupt row explicit"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_corrupt_record_preserved
       report);
  check bool
    "invalid row explicit"
    true
    (report_has_kind Fs_compat.Publication_recovery_invalid_record_name report);
  (match Recovery.with_lane ~registry ~owner:owner_name (fun _ -> ()) with
   | Error (Recovery.Reconciliation_blocked _) -> ()
   | Error error -> fail (Recovery.lane_open_error_to_string error)
   | Ok _ -> fail "blocked owner was admitted");
  with_lane_ok registry "unrelated-owner"
;;

let test_transition_failure_is_explicit () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "transition-failure" in
  let operation_id = operation_id "55555555-5555-4555-8555-555555555555" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_forensic
    ~record_name:(Uuidm.to_string operation_id)
    "{not-the-derived-forensic-record";
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "blocked" false (report_ready report);
  check bool
    "transition failure explicit"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_record_transition_failed
       report)
;;

let test_missing_area_preserves_sources_and_continues_inventory () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "missing-forensic" in
  let prepared_id = operation_id "66666666-6666-4666-8666-666666666666" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:prepared_id
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_owned
    ~record_name:"77777777-7777-4777-8777-777777777777"
    "{corrupt-owned";
  let forensic_path = owner_area_path ~registry_root ~owner:owner_name "forensic" in
  Unix.rmdir forensic_path;
  let active_record =
    Filename.concat
      (owner_area_path ~registry_root ~owner:owner_name "active")
      (Uuidm.to_string prepared_id)
  in
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "owner remains blocked" false (report_ready report);
  check bool
    "missing forensic area is explicit"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_area_inventory_unavailable
       report);
  check bool
    "prepared source retains unavailable transition evidence"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_source_transition_capabilities_unavailable
       report);
  check bool
    "owned area continued to corrupt record"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_corrupt_record_preserved
       report);
  check bool "prepared source remains" true (Sys.file_exists active_record);
  check bool "missing area was not recreated" false (Sys.file_exists forensic_path)
;;

let test_counterpart_area_unavailable_preserves_prepared_source () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "counterpart-owned-unavailable" in
  let prepared_id = operation_id "88888888-8888-4888-8888-888888888888" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:prepared_id
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owned_path = owner_area_path ~registry_root ~owner:owner_name "owned" in
  Unix.rmdir owned_path;
  let active_record =
    Filename.concat
      (owner_area_path ~registry_root ~owner:owner_name "active")
      (Uuidm.to_string prepared_id)
  in
  let forensic_record =
    Filename.concat
      (owner_area_path ~registry_root ~owner:owner_name "forensic")
      (Uuidm.to_string prepared_id)
  in
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "owner remains blocked" false (report_ready report);
  check bool
    "counterpart area failure is explicit"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_area_inventory_unavailable
       report);
  check bool
    "source transition is fenced"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_source_transition_capabilities_unavailable
       report);
  check bool "prepared source remains" true (Sys.file_exists active_record);
  check bool "forensic record was not created" false (Sys.file_exists forensic_record);
  check bool "missing counterpart was not recreated" false (Sys.file_exists owned_path)
;;

let test_unexpected_lane_entry_is_preserved_and_blocks_owner () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "lane-residue" in
  with_registry ~fs ~registry_root @@ fun registry ->
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_active
    ~record_name:"not-a-record"
    "source-sentinel";
  let residue_path =
    Filename.concat
      (owner_lane_path ~registry_root ~owner:owner_name)
      "operator-residue"
  in
  let residue_content = "operator-owned-lane-sentinel" in
  Out_channel.with_open_bin residue_path (fun channel ->
    Out_channel.output_string channel residue_content);
  let residue_before = Unix.lstat residue_path in
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "owner remains blocked" false (report_ready report);
  check bool
    "lane residue is explicit"
    true
    (report_has_kind Fs_compat.Publication_recovery_unexpected_lane_entry report);
  let residue_after = Unix.lstat residue_path in
  check int "residue inode unchanged" residue_before.st_ino residue_after.st_ino;
  check string
    "residue content unchanged"
    residue_content
    (In_channel.with_open_bin residue_path In_channel.input_all)
;;

let test_wrong_area_permissions_are_not_repaired () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "wrong-area-mode" in
  with_registry ~fs ~registry_root @@ fun registry ->
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_active
    ~record_name:"not-a-record"
    "source-sentinel";
  let owned_path = owner_area_path ~registry_root ~owner:owner_name "owned" in
  Unix.chmod owned_path 0o750;
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "owner remains blocked" false (report_ready report);
  check bool
    "wrong permission area is explicit"
    true
    (report_has_kind
       Fs_compat.Publication_recovery_area_inventory_unavailable
       report);
  check bool
    "active area still inventoried"
    true
    (report_has_kind Fs_compat.Publication_recovery_invalid_record_name report);
  check int
    "startup reconciliation did not chmod"
    0o750
    ((Unix.stat owned_path).st_perm land 0o7777)
;;

let test_existing_registry_permissions_are_not_repaired () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  with_registry ~fs ~registry_root (fun _ -> ());
  let recovery_root = Filename.concat registry_root "fs-publication-recovery" in
  Unix.chmod recovery_root 0o750;
  let result =
    Eio.Switch.run @@ fun sw ->
    Recovery.open_registry
      ~sw
      ~fs
      ~registry_root:Eio.Path.(fs / registry_root)
  in
  (match result with
   | Error _ -> ()
   | Ok _ -> fail "wrong-mode existing registry was silently repaired");
  check int
    "existing registry mode unchanged"
    0o750
    ((Unix.stat recovery_root).st_perm land 0o7777)
;;

let test_existing_lane_permissions_are_not_repaired () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "wrong-existing-lane-mode" in
  with_registry ~fs ~registry_root @@ fun registry ->
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_active
    ~record_name:"not-a-record"
    "source-sentinel";
  let lane = owner_lane_path ~registry_root ~owner:owner_name in
  Unix.chmod lane 0o750;
  let result =
    Fs_compat.Capability_write_for_testing.write_raw_publication_recovery_record
      ~registry
      ~owner:owner_name
      ~area:Fs_compat.Publication_recovery_active
      ~record_name:"second-record"
      ~raw:"must-not-be-written"
  in
  (match result with
   | Error _ -> ()
   | Ok () -> fail "wrong-mode existing lane was silently repaired");
  check int
    "existing lane mode unchanged"
    0o750
    ((Unix.stat lane).st_perm land 0o7777);
  check bool
    "second record was not written"
    false
    (Sys.file_exists
       (Filename.concat
          (owner_area_path ~registry_root ~owner:owner_name "active")
          "second-record"))
;;

let test_exact_demand_reconciles_without_discovery () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "demand-before-discovery" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "11111111-1111-4111-8111-111111111111")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  with_lane_ok registry owner_name;
  let snapshot = Recovery.For_testing.snapshot registry in
  (match snapshot.discovery with
   | Recovery.Snapshot_discovery_required -> ()
   | Recovery.Snapshot_discovery_running
   | Recovery.Snapshot_discovery_failed _
   | Recovery.Snapshot_discovery_complete _ ->
     fail "exact demand incorrectly drove global discovery");
  match find_owner_snapshot registry owner_name with
  | Some (Recovery.Snapshot_owner_ready (_, report)) ->
    check bool "exact owner report is ready" true (Recovery.report_is_ready report)
  | Some _ -> fail "exact demand did not reach ready"
  | None -> fail "exact demanded owner was not retained"
;;

let test_discovery_does_not_prepopulate_demand_registry () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_a = "observed-owner-a" in
  let owner_b = "observed-owner-b" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_a
    ~operation_id:(operation_id "12121212-1212-4212-8212-121212121212")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  seed_prepared
    ~registry
    ~owner:owner_b
    ~operation_id:(operation_id "13131313-1313-4313-8313-131313131313")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let rows =
    match Recovery.discover_owners registry with
    | Ok rows -> rows
    | Error error -> fail (Recovery.discovery_error_to_string error)
  in
  check int "two owners discovered" 2 (List.length rows);
  check int
    "discovery creates no demand entries"
    0
    (List.length (Recovery.For_testing.snapshot registry).owners);
  with_lane_ok registry owner_a;
  let owners = (Recovery.For_testing.snapshot registry).owners in
  check int "only exact demanded owner is tracked" 1 (List.length owners);
  check bool
    "owner A is tracked"
    true
    (List.exists
       (fun owner -> String.equal (snapshot_owner_name owner) owner_a)
       owners);
  check bool
    "discovered owner B remains observational"
    false
    (List.exists
       (fun owner -> String.equal (snapshot_owner_name owner) owner_b)
       owners)
;;

let test_discovery_suspension_does_not_block_exact_demand () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  with_registry ~fs ~registry_root @@ fun registry ->
  let discovery_started, resolve_discovery_started = Eio.Promise.create () in
  let release_discovery, resolve_release_discovery = Eio.Promise.create () in
  let discovery_result, resolve_discovery_result = Eio.Promise.create () in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      Recovery.For_testing.discover_owners
        ~before_discovery:(fun () ->
          Eio.Promise.resolve resolve_discovery_started ();
          Eio.Promise.await release_discovery)
        registry
    in
    Eio.Promise.resolve resolve_discovery_result result);
  Eio.Promise.await discovery_started;
  (match Recovery.For_testing.discovery_phase registry with
   | Recovery.For_testing.Discovery_running -> ()
   | Recovery.For_testing.Discovery_required
   | Recovery.For_testing.Discovery_failed
   | Recovery.For_testing.Discovery_complete ->
     fail "suspended discovery did not remain Running");
  with_lane_ok registry "absent-while-discovering";
  (match find_owner_snapshot registry "absent-while-discovering" with
   | Some (Recovery.Snapshot_owner_ready_without_obligation _) -> ()
   | Some _ -> fail "exact absent owner did not settle independently"
   | None -> fail "exact absent owner demand was not retained");
  (match Recovery.For_testing.discovery_settlement registry with
   | Recovery.For_testing.Discovery_unsettled -> ()
   | Recovery.For_testing.Discovery_settled ->
     fail "exact demand incorrectly settled discovery");
  Eio.Promise.resolve resolve_release_discovery ();
  (match Eio.Promise.await discovery_result with
   | Ok _ -> ()
   | Error error -> fail (Recovery.discovery_error_to_string error));
  Recovery.For_testing.await_discovery_settlement registry;
  match Recovery.For_testing.discovery_phase registry with
  | Recovery.For_testing.Discovery_complete -> ()
  | Recovery.For_testing.Discovery_required
  | Recovery.For_testing.Discovery_running
  | Recovery.For_testing.Discovery_failed ->
    fail "successful discovery did not settle Complete"
;;

let test_suspended_owner_does_not_block_unrelated_owner () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_a_name = "suspended-owner-a" in
  let owner_b_name = "independent-owner-b" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_a_name
    ~operation_id:(operation_id "20202020-2020-4020-8020-202020202020")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  seed_prepared
    ~registry
    ~owner:owner_b_name
    ~operation_id:(operation_id "21212121-2121-4121-8121-212121212121")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner_a = discover_owner registry owner_a_name in
  let inventory_started, resolve_inventory_started = Eio.Promise.create () in
  let release_inventory, resolve_release_inventory = Eio.Promise.create () in
  let inventory_result, resolve_inventory_result = Eio.Promise.create () in
  let crash = Failure "deterministic owner inventory crash" in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      Recovery.For_testing.inspect_owner
        ~before_inspection:(fun () ->
          Eio.Promise.resolve resolve_inventory_started ();
          Eio.Promise.await release_inventory;
          raise crash)
        ~registry
        ~owner:owner_a
    in
    Eio.Promise.resolve resolve_inventory_result result);
  Eio.Promise.await inventory_started;
  with_lane_ok registry owner_b_name;
  check bool
    "owner A remains running while B completes"
    true
    (match find_owner_snapshot registry owner_a_name with
     | Some (Recovery.Snapshot_owner_inventory_running _) -> true
     | Some _ | None -> false);
  Eio.Promise.resolve resolve_release_inventory ();
  (match Eio.Promise.await inventory_result with
   | Ok (Recovery.Owner_inventory_crashed { owner; exception_; _ }) ->
     check string "exact crashed owner" owner_a_name (Recovery.owner_to_string owner);
     check bool "exact crash retained" true (exception_ == crash)
   | Ok row ->
     failf "expected owner-local crash, got %s" (Recovery.owner_inventory_row_to_string row)
   | Error error -> fail (Recovery.inspection_error_to_string error));
  match Recovery.with_lane ~registry ~owner:owner_a_name (fun _ -> ()) with
  | Error
      (Recovery.Reconciliation_blocked
        (Recovery.Owner_inventory_block
          (Recovery.Owner_inventory_crashed { exception_; _ }))) ->
    check bool "blocked owner retains crash" true (exception_ == crash)
  | Error error -> fail (Recovery.lane_open_error_to_string error)
  | Ok _ -> fail "crashed owner was admitted"
;;

let test_discovery_failure_is_degraded_and_demand_independent () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "demand-after-discovery-failure" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "30303030-3030-4030-8030-303030303030")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let crash = Failure "deterministic registry discovery crash" in
  (match
     Recovery.For_testing.discover_owners
       ~before_discovery:(fun () -> raise crash)
       registry
   with
   | Error
       (Recovery.Registry_discovery_terminal
         (Recovery.Registry_discovery_crashed { exception_; _ })) ->
     check bool "exact discovery crash retained" true (exception_ == crash)
   | Error error -> fail (Recovery.discovery_error_to_string error)
   | Ok _ -> fail "crashed discovery returned rows");
  with_lane_ok registry owner_name;
  with_lane_ok registry "absent-after-discovery-failure";
  (match Recovery.For_testing.snapshot registry with
   | { discovery = Recovery.Snapshot_discovery_failed
         (Recovery.Registry_discovery_crashed { exception_; _ }); _ } ->
     check bool "snapshot retains discovery crash" true (exception_ == crash)
   | _ -> fail "discovery failure was not retained as observation");
  match
    Recovery.For_testing.discover_owners
      ~before_discovery:(fun () -> fail "terminal discovery was retried")
      registry
  with
  | Error
      (Recovery.Registry_discovery_terminal
        (Recovery.Registry_discovery_crashed { exception_; _ })) ->
    check bool "terminal discovery remains immutable" true (exception_ == crash)
  | Error error -> fail (Recovery.discovery_error_to_string error)
  | Ok _ -> fail "terminal discovery was silently reset"
;;

let test_non_current_inventory_cancellation_is_owner_local () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "inventory-cancelled-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "40404040-4040-4040-8040-404040404040")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = discover_owner registry owner_name in
  let reason = Failure "deterministic non-current inventory cancellation" in
  (match
     Recovery.For_testing.inspect_owner
       ~before_inspection:(fun () -> raise (Eio.Cancel.Cancelled reason))
       ~registry
       ~owner
   with
   | Ok (Recovery.Owner_inventory_cancelled { reason = observed; _ }) ->
     check bool "exact cancellation retained" true (observed == reason)
   | Ok row ->
     failf "expected cancellation row, got %s" (Recovery.owner_inventory_row_to_string row)
   | Error error -> fail (Recovery.inspection_error_to_string error));
  Eio.Fiber.check ();
  (match Recovery.with_lane ~registry ~owner:owner_name (fun _ -> ()) with
   | Error
       (Recovery.Reconciliation_blocked
         (Recovery.Owner_inventory_block
           (Recovery.Owner_inventory_cancelled { reason = observed; _ }))) ->
     check bool "exact blocked reason retained" true (observed == reason)
   | Error error -> fail (Recovery.lane_open_error_to_string error)
   | Ok _ -> fail "inventory-cancelled owner was admitted");
  with_lane_ok registry "unrelated-after-inventory-cancel"
;;

let test_non_current_reconciliation_cancellation_is_typed () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "reconciliation-cancelled-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "50505050-5050-4050-8050-505050505050")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner =
    inspect_valid ~registry ~owner:(discover_owner registry owner_name)
  in
  let reason = Failure "deterministic non-current reconciliation cancellation" in
  (match
     Recovery.For_testing.interrupt_reconciliation
       ~registry
       ~owner
       (Recovery.For_testing.Cancel_reconciliation reason)
   with
   | Error (Recovery.Owner_reconciliation_cancelled { reason = observed; _ }) ->
     check bool "typed cancellation retains reason" true (observed == reason)
   | Error error -> fail (Recovery.reconciliation_error_to_string error)
   | Ok _ -> fail "cancelled reconciliation returned a report");
  Eio.Fiber.check ();
  (match Recovery.with_lane ~registry ~owner:owner_name (fun _ -> ()) with
   | Error
       (Recovery.Reconciliation_blocked
         (Recovery.Owner_reconciliation_cancelled_block
           { reason = observed; _ })) ->
     check bool "lane block retains reason" true (observed == reason)
   | Error error -> fail (Recovery.lane_open_error_to_string error)
   | Ok _ -> fail "cancelled owner was admitted");
  with_lane_ok registry "unrelated-after-reconciliation-cancel"
;;

let test_reconciliation_crash_is_typed_and_owner_local () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "reconciliation-crashed-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "60606060-6060-4060-8060-606060606060")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner =
    inspect_valid ~registry ~owner:(discover_owner registry owner_name)
  in
  let crash = Failure "deterministic reconciliation crash" in
  (match
     Recovery.For_testing.interrupt_reconciliation
       ~registry
       ~owner
       (Recovery.For_testing.Crash_reconciliation crash)
   with
   | Error (Recovery.Owner_reconciliation_crashed { exception_; _ }) ->
     check bool "typed crash retains exception" true (exception_ == crash)
   | Error error -> fail (Recovery.reconciliation_error_to_string error)
   | Ok _ -> fail "crashed reconciliation returned a report");
  (match Recovery.with_lane ~registry ~owner:owner_name (fun _ -> ()) with
   | Error
       (Recovery.Reconciliation_blocked
         (Recovery.Owner_reconciliation_crash { exception_; _ })) ->
     check bool "lane block retains crash" true (exception_ == crash)
   | Error error -> fail (Recovery.lane_open_error_to_string error)
   | Ok _ -> fail "crashed owner was admitted");
  with_lane_ok registry "unrelated-after-reconciliation-crash"
;;

type 'a terminalization_outcome =
  | Terminalization_returned of 'a
  | Terminalization_cancelled of exn

let cancel_while_terminalization_waits_for_lock ~registry operation =
  let context_ready, resolve_context_ready = Eio.Promise.create () in
  let terminalization_ready, resolve_terminalization_ready =
    Eio.Promise.create ()
  in
  let allow_terminalization, resolve_allow_terminalization =
    Eio.Promise.create ()
  in
  let entering_terminalization, resolve_entering_terminalization =
    Eio.Promise.create ()
  in
  let lock_held, resolve_lock_held = Eio.Promise.create () in
  let release_lock, resolve_release_lock = Eio.Promise.create () in
  let cancellation_reason = Failure "terminalization lock cancellation" in
  Eio.Switch.run @@ fun sw ->
  let operation_result =
    Eio.Fiber.fork_promise ~sw (fun () ->
      try
        Eio.Cancel.sub @@ fun context ->
        Eio.Promise.resolve resolve_context_ready context;
        Terminalization_returned
          (operation ~before_terminalization:(fun () ->
             Eio.Promise.resolve resolve_terminalization_ready ();
             Eio.Promise.await allow_terminalization;
             Eio.Promise.resolve resolve_entering_terminalization ()))
      with
      | Eio.Cancel.Cancelled observed ->
        Terminalization_cancelled observed)
  in
  let context = Eio.Promise.await context_ready in
  Eio.Promise.await terminalization_ready;
  Eio.Fiber.fork ~sw (fun () ->
    Recovery.For_testing.with_readiness_lock registry (fun () ->
      Eio.Promise.resolve resolve_lock_held ();
      Eio.Promise.await release_lock));
  Eio.Promise.await lock_held;
  Eio.Promise.resolve resolve_allow_terminalization ();
  (* The operation resolves this immediately before returning from the test
     hook. It then runs without a scheduling point until the held production
     mutex suspends it, so this await observes the exact finish-lock wait. *)
  Eio.Promise.await entering_terminalization;
  Eio.Cancel.cancel context cancellation_reason;
  Eio.Promise.resolve resolve_release_lock ();
  match Eio.Promise.await_exn operation_result with
  | Terminalization_cancelled observed ->
    check bool
      "current cancellation remains primary"
      true
      (observed == cancellation_reason)
  | Terminalization_returned _ ->
    fail "terminalization lock wait swallowed current cancellation"
;;

let test_discovery_terminalizes_after_lock_wait_cancellation () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:"discovery-lock-owner"
    ~operation_id:(operation_id "91919191-9191-4191-8191-919191919191")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  cancel_while_terminalization_waits_for_lock
    ~registry
    (fun ~before_terminalization ->
      Recovery.For_testing.discover_owners_terminalization
        ~before_terminalization
        registry);
  (match Recovery.For_testing.discovery_phase registry with
   | Recovery.For_testing.Discovery_complete -> ()
   | Recovery.For_testing.Discovery_required
   | Recovery.For_testing.Discovery_running
   | Recovery.For_testing.Discovery_failed ->
     fail "discovery did not publish its terminal state");
  (match Recovery.For_testing.discovery_settlement registry with
   | Recovery.For_testing.Discovery_settled -> ()
   | Recovery.For_testing.Discovery_unsettled ->
     fail "discovery promise remained unsettled");
  check int
    "discovery remains observational"
    0
    (List.length (Recovery.For_testing.snapshot registry).owners)
;;

let test_inspection_progresses_after_lock_wait_cancellation () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "inspection-lock-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "92929292-9292-4292-8292-929292929292")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = discover_owner registry owner_name in
  cancel_while_terminalization_waits_for_lock
    ~registry
    (fun ~before_terminalization ->
      Recovery.For_testing.inspect_owner_terminalization
        ~before_terminalization
        ~registry
        ~owner);
  (match find_owner_snapshot registry owner_name with
   | Some (Recovery.Snapshot_owner_reconciliation_pending _) -> ()
   | Some _ -> fail "inspection did not publish reconciliation pending"
   | None -> fail "inspection owner disappeared");
  with_lane_ok registry owner_name;
  match Recovery.For_testing.owner_settlement registry owner with
  | Recovery.For_testing.Owner_settled -> ()
  | Recovery.For_testing.Owner_untracked
  | Recovery.For_testing.Owner_unsettled ->
    fail "next demand did not settle inspected owner"
;;

let test_reconciliation_terminalizes_after_lock_wait_cancellation () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "reconciliation-lock-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "93939393-9393-4393-8393-939393939393")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inspect_valid ~registry ~owner:(discover_owner registry owner_name) in
  cancel_while_terminalization_waits_for_lock
    ~registry
    (fun ~before_terminalization ->
      Recovery.For_testing.reconcile_owner_terminalization
        ~before_terminalization
        ~registry
        ~owner);
  (match find_owner_snapshot registry owner_name with
   | Some (Recovery.Snapshot_owner_ready _) -> ()
   | Some _ -> fail "reconciliation did not publish its terminal report"
   | None -> fail "reconciled owner disappeared");
  (match Recovery.For_testing.owner_settlement registry owner with
   | Recovery.For_testing.Owner_settled -> ()
   | Recovery.For_testing.Owner_untracked
   | Recovery.For_testing.Owner_unsettled ->
     fail "reconciliation promise remained unsettled");
  with_lane_ok registry owner_name
;;

type generation_reset_stage =
  | Inventory_generation_reset
  | Reconciliation_generation_reset

let generation_reset_stage_name = function
  | Inventory_generation_reset -> "inventory"
  | Reconciliation_generation_reset -> "reconciliation"
;;

let run_generation_reset_race stage () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let stage_name = generation_reset_stage_name stage in
  let owner_name = stage_name ^ "-generation-reset-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:
      (operation_id
         (match stage with
          | Inventory_generation_reset ->
            "70707070-7070-4070-8070-707070707070"
          | Reconciliation_generation_reset ->
            "80808080-8080-4080-8080-808080808080"))
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = discover_owner registry owner_name in
  (match stage with
   | Inventory_generation_reset -> ()
   | Reconciliation_generation_reset -> ignore (inspect_valid ~registry ~owner));
  let context_ready, resolve_context_ready = Eio.Promise.create () in
  let operation_running, resolve_operation_running = Eio.Promise.create () in
  let operation_cancelled, resolve_operation_cancelled = Eio.Promise.create () in
  let first_wait, resolve_first_wait = Eio.Promise.create () in
  let waiter_after_first, resolve_waiter_after_first = Eio.Promise.create () in
  let release_waiter, resolve_release_waiter = Eio.Promise.create () in
  let fresh_running, resolve_fresh_running = Eio.Promise.create () in
  let release_fresh, resolve_release_fresh = Eio.Promise.create () in
  let second_wait, resolve_second_wait = Eio.Promise.create () in
  let first_generation = ref None in
  let second_generation = ref None in
  let before_owner_settlement_wait generation =
    match !first_generation with
    | None ->
      first_generation := Some generation;
      Eio.Promise.resolve resolve_first_wait ()
    | Some first when first == generation -> ()
    | Some _ ->
      second_generation := Some generation;
      ignore (Eio.Promise.try_resolve resolve_second_wait ())
  in
  let after_owner_settlement generation =
    match !first_generation with
    | Some first when first == generation ->
      if Eio.Promise.try_resolve resolve_waiter_after_first ()
      then Eio.Promise.await release_waiter
    | Some _ | None -> ()
  in
  let cancellation_reason = Failure (stage_name ^ " current cancellation") in
  let run_cancelled_generation () =
    Eio.Cancel.sub @@ fun context ->
    Eio.Promise.resolve resolve_context_ready context;
    match
      (match stage with
       | Inventory_generation_reset ->
         Recovery.For_testing.inspect_owner
           ~before_inspection:(fun () ->
             Eio.Promise.resolve resolve_operation_running ();
             Eio.Fiber.await_cancel ())
           ~registry
           ~owner
         |> ignore
       | Reconciliation_generation_reset ->
         Recovery.For_testing.reconcile_owner
           ~before_reconciliation:(fun () ->
             Eio.Promise.resolve resolve_operation_running ();
             Eio.Fiber.await_cancel ())
           ~registry
           ~owner
         |> ignore)
    with
    | () -> fail "current-cancelled generation returned"
    | exception Eio.Cancel.Cancelled observed ->
      Eio.Cancel.protect (fun () ->
        check bool "original current cancellation" true (observed == cancellation_reason);
        Eio.Promise.resolve resolve_operation_cancelled ())
  in
  let run_fresh_generation () =
    match stage with
    | Inventory_generation_reset ->
      ignore
        (Recovery.For_testing.inspect_owner
           ~before_inspection:(fun () ->
             Eio.Promise.resolve resolve_fresh_running ();
             Eio.Promise.await release_fresh)
           ~registry
           ~owner);
      ignore (Recovery.reconcile_owner ~registry ~owner)
    | Reconciliation_generation_reset ->
      Recovery.For_testing.reconcile_owner
        ~before_reconciliation:(fun () ->
          Eio.Promise.resolve resolve_fresh_running ();
          Eio.Promise.await release_fresh)
        ~registry
        ~owner
      |> ignore
  in
  Eio.Fiber.both
    run_cancelled_generation
    (fun () ->
       let context = Eio.Promise.await context_ready in
       Eio.Promise.await operation_running;
       Eio.Switch.run @@ fun sw ->
       let waiter =
         Eio.Fiber.fork_promise ~sw (fun () ->
           Recovery.For_testing.ensure_owner_ready
             ~before_owner_settlement_wait
             ~after_owner_settlement
             ~registry
             ~owner:owner_name)
       in
       Eio.Promise.await first_wait;
       Eio.Cancel.cancel context cancellation_reason;
       Eio.Promise.await operation_cancelled;
       Eio.Promise.await waiter_after_first;
       let fresh = Eio.Fiber.fork_promise ~sw run_fresh_generation in
       Eio.Promise.await fresh_running;
       Eio.Promise.resolve resolve_release_waiter ();
       Eio.Promise.await second_wait;
       let first = Option.get !first_generation in
       let second = Option.get !second_generation in
       check bool "generation token changed" true (first != second);
       check bool "retired generation settled" true (Option.is_some (Eio.Promise.peek first));
       check bool "fresh running generation unsettled" true (Option.is_none (Eio.Promise.peek second));
       check bool "waiter follows fresh generation" true (Option.is_none (Eio.Promise.peek waiter));
       Eio.Promise.resolve resolve_release_fresh ();
       Eio.Promise.await_exn fresh;
       match Eio.Promise.await_exn waiter with
       | Ok () -> ()
       | Error error -> fail (Recovery.lane_open_error_to_string error));
  match find_owner_snapshot registry owner_name with
  | Some (Recovery.Snapshot_owner_ready _) -> ()
  | Some _ -> fail "fresh generation did not reach ready"
  | None -> fail "fresh generation owner disappeared"
;;

let test_inventory_generation_reset_race =
  run_generation_reset_race Inventory_generation_reset
;;

let test_reconciliation_generation_reset_race =
  run_generation_reset_race Reconciliation_generation_reset
;;

let test_waiter_progresses_when_inspection_winner_cancels_after_transition () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "inspection-transition-cancelled-winner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "78787878-7878-4878-8878-787878787878")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = discover_owner registry owner_name in
  let context_ready, resolve_context_ready = Eio.Promise.create () in
  let terminalization_ready, resolve_terminalization_ready =
    Eio.Promise.create ()
  in
  let cancellation_sent, resolve_cancellation_sent = Eio.Promise.create () in
  let waiter_waiting, resolve_waiter_waiting = Eio.Promise.create () in
  let cancellation_reason = Failure "inspection winner cancelled after transition" in
  Eio.Switch.run @@ fun sw ->
  let winner =
    Eio.Fiber.fork_promise ~sw (fun () ->
      try
        Eio.Cancel.sub @@ fun context ->
        Eio.Promise.resolve resolve_context_ready context;
        Recovery.For_testing.inspect_owner_terminalization
          ~before_terminalization:(fun () ->
            Eio.Promise.resolve resolve_terminalization_ready ();
            Eio.Cancel.protect (fun () -> Eio.Promise.await cancellation_sent))
          ~registry
          ~owner
        |> ignore;
        `Returned
      with
      | Eio.Cancel.Cancelled observed -> `Cancelled observed)
  in
  let context = Eio.Promise.await context_ready in
  Eio.Promise.await terminalization_ready;
  let waiter =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Recovery.For_testing.ensure_owner_ready
        ~before_owner_settlement_wait:(fun _ ->
          ignore (Eio.Promise.try_resolve resolve_waiter_waiting ()))
        ~after_owner_settlement:(fun _ -> ())
        ~registry
        ~owner:owner_name)
  in
  Eio.Promise.await waiter_waiting;
  Eio.Cancel.cancel context cancellation_reason;
  Eio.Promise.resolve resolve_cancellation_sent ();
  (match Eio.Promise.await_exn winner with
   | `Cancelled observed ->
     check bool "inspection winner retains cancellation" true
       (observed == cancellation_reason)
   | `Returned -> fail "inspection winner swallowed cancellation");
  (match Eio.Promise.await_exn waiter with
   | Ok () -> ()
   | Error error -> fail (Recovery.lane_open_error_to_string error));
  match find_owner_snapshot registry owner_name with
  | Some (Recovery.Snapshot_owner_ready _) -> ()
  | Some _ -> fail "waiting demander did not finish reconciliation"
  | None -> fail "inspection transition lost exact owner state"
;;

let require_json_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> failf "structured report omitted field %S" name)
  | json ->
    failf
      "expected JSON object while reading %S, got %s"
      name
      (Yojson.Safe.to_string json)
;;

let contains_exact_substring ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec search index =
    if index + needle_length > haystack_length
    then false
    else if String.sub haystack index needle_length = needle
    then true
    else search (index + 1)
  in
  needle_length = 0 || search 0
;;

let test_structured_report_preserves_corrupt_evidence () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "structured-corrupt-owner" in
  let secret = "operator-secret-must-remain-forensic-only" in
  let record_name = "cccccccc-cccc-4ccc-8ccc-cccccccccccc" in
  let raw =
    Yojson.Safe.to_string
      (`Assoc
         [ "schema", `String "masc.fs-publication-recovery"
         ; "version", `Int 1
         ; "state", `String "prepared"
         ; "owner", `Assoc [ "secret", `String secret ]
         ; "operation_id", `String record_name
         ; "allowed_root_path", `String "/unused"
         ; ( "allowed_root"
           , `Assoc [ "dev", `String "1"; "ino", `String "1" ] )
         ; "parent_components", `List []
         ; "parent", `Assoc [ "dev", `String "1"; "ino", `String "1" ]
         ; "target_leaf", `String "target.json"
         ; "initial_target", `Assoc [ "presence", `String "absent" ]
         ; "permissions", `Int 0o600
         ])
  in
  with_registry ~fs ~registry_root @@ fun registry ->
  write_raw
    ~registry
    ~owner:owner_name
    ~area:Fs_compat.Publication_recovery_active
    ~record_name
    raw;
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  let json =
    Fs_compat.publication_recovery_reconciliation_report_to_yojson report
  in
  let json_text = Yojson.Safe.to_string json in
  check bool
    "structured report excludes crafted secret"
    false
    (contains_exact_substring ~needle:secret json_text);
  check bool
    "diagnostic report excludes crafted secret"
    false
    (contains_exact_substring ~needle:secret (report_text report));
  check bool
    "structured report excludes forensic raw payload"
    false
    (contains_exact_substring ~needle:raw json_text);
  check (option string)
    "structured owner"
    (Some owner_name)
    (match require_json_field "owner" json with
     | `String owner -> Some owner
     | _ -> None);
  check bool
    "structured readiness"
    false
    (match require_json_field "ready" json with
     | `Bool ready -> ready
     | value ->
       failf
         "structured ready field has wrong shape: %s"
         (Yojson.Safe.to_string value));
  let rows =
    match require_json_field "rows" json with
    | `List rows -> rows
    | value ->
      failf
        "structured rows field has wrong shape: %s"
        (Yojson.Safe.to_string value)
  in
  let corrupt =
    List.find_opt
      (fun row ->
        match require_json_field "kind" row with
        | `String "corrupt_record_preserved" -> true
        | `String _ -> false
        | value ->
          failf
            "structured row kind has wrong shape: %s"
            (Yojson.Safe.to_string value))
      rows
  in
  match corrupt with
  | None -> fail "structured report omitted corrupt record row"
  | Some corrupt ->
    check bool
      "structured report does not duplicate raw record"
      true
      (match corrupt with
       | `Assoc fields -> Option.is_none (List.assoc_opt "raw" fields)
       | _ -> false);
    check int
      "structured raw byte count"
      (String.length raw)
      (match require_json_field "raw_byte_count" corrupt with
       | `Int value -> value
       | value ->
         failf
           "structured raw byte count has wrong shape: %s"
           (Yojson.Safe.to_string value));
    check (option string)
      "structured raw SHA-256"
      (Some Digestif.SHA256.(digest_string raw |> to_hex))
      (match require_json_field "raw_sha256" corrupt with
       | `String value -> Some value
       | _ -> None);
    check (option string)
      "structured operation id"
      (Some record_name)
      (match require_json_field "operation_id" corrupt with
       | `String value -> Some value
       | _ -> None);
    let validation_error = require_json_field "validation_error" corrupt in
    check (option string)
      "typed corrupt validation kind"
      (Some "record_field_invalid")
      (match require_json_field "kind" validation_error with
       | `String value -> Some value
       | _ -> None);
    let payload = require_json_field "payload" validation_error in
    let canonical_payload =
      `Assoc
        [ "field", `String "owner"
        ; "value", `Assoc [ "secret", `String secret ]
        ]
      |> Yojson.Safe.sort
      |> Yojson.Safe.to_string
    in
    check int
      "canonical validation payload byte count"
      (String.length canonical_payload)
      (match require_json_field "canonical_json_byte_count" payload with
       | `Int value -> value
       | value ->
         failf
           "validation payload byte count has wrong shape: %s"
           (Yojson.Safe.to_string value));
    check (option string)
      "canonical validation payload SHA-256"
      (Some Digestif.SHA256.(digest_string canonical_payload |> to_hex))
      (match require_json_field "canonical_json_sha256" payload with
       | `String value -> Some value
       | _ -> None)
;;

let test_health_counter_transitions_are_checked () =
  (match
     Recovery.For_testing.health_counter_transition
       ~counter:Recovery.Inspection_pending_counter
       ~change:Recovery.Increment_health_counter
       ~value:Int.max_int
   with
   | Error
       (Recovery.Health_counter_overflow
         Recovery.Inspection_pending_counter) -> ()
   | Error _ -> fail "max_int increment reported the wrong invariant"
   | Ok _ -> fail "max_int increment wrapped without an invariant");
  (match
     Recovery.For_testing.health_counter_transition
       ~counter:Recovery.Ready_counter
       ~change:Recovery.Decrement_health_counter
       ~value:0
   with
   | Error (Recovery.Health_counter_underflow Recovery.Ready_counter) ->
     ()
   | Error _ -> fail "zero decrement reported the wrong invariant"
   | Ok _ -> fail "zero decrement became negative without an invariant");
  match
    Recovery.For_testing.health_counter_transition
      ~counter:Recovery.Blocked_counter
      ~change:Recovery.Increment_health_counter
      ~value:0
  with
  | Ok 1 -> ()
  | Ok value -> failf "checked increment returned %d" value
  | Error _ -> fail "ordinary checked increment failed"
;;

let test_retryable_lane_store_health_tracks_exact_owner () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  with_registry ~fs ~registry_root @@ fun registry ->
  let owner = "retryable-lane-store-health" in
  let exception_ = Failure "deterministic lane store failure" in
  let backtrace =
    try raise exception_ with
    | observed ->
      check bool "exact injected store failure" true (observed == exception_);
      Printexc.get_raw_backtrace ()
  in
  let record_failure () =
    match
      Recovery.For_testing.record_lane_store_open_failure
        ~registry
        ~owner
        ~exception_
        ~backtrace
    with
    | Ok () -> ()
    | Error error -> fail (Recovery.validation_error_to_string error)
  in
  record_failure ();
  check int
    "one exact owner failure is aggregated"
    1
    (Recovery.health_snapshot registry).retryable_lane_failure_count;
  record_failure ();
  check int
    "retrying the same owner does not double count"
    1
    (Recovery.health_snapshot registry).retryable_lane_failure_count;
  (match
     Recovery.For_testing.record_lane_store_open_success
       ~registry
       ~owner
   with
   | Ok () -> ()
   | Error error -> fail (Recovery.validation_error_to_string error));
  check int
    "successful exact lane open clears its retained failure"
    0
    (Recovery.health_snapshot registry).retryable_lane_failure_count
;;

let test_single_borrow_drains_exactly_once () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  with_registry ~fs ~registry_root @@ fun registry ->
  with_lane_ok registry "single-borrow-owner";
  match Recovery.For_testing.single_borrow_balance ~registry ~owner:"single-borrow-owner" with
  | Ok
      (Recovery.For_testing.Single_borrow_balance
        { during_borrow; after_release; close_completed }) ->
    check int "one borrow increments once" 1 during_borrow;
    check int "one release drains to zero" 0 after_release;
    check bool "zero-count close completes" true close_completed
  | Ok Recovery.For_testing.Single_borrow_rejected ->
    fail "fresh access rejected its first borrow"
  | Ok (Recovery.For_testing.Single_borrow_invariant _) ->
    fail "fresh access reached an invariant violation"
  | Ok (Recovery.For_testing.Single_borrow_raised failure) ->
    failf "fresh access raised: %s" (Printexc.to_string failure.exception_)
  | Error error -> fail (Recovery.lane_open_error_to_string error)
;;

let () =
  run
    "fs_compat publication reconciliation"
    [ ( "recovery evidence preservation"
      , [ test_case
            "prepared absent becomes forensic"
            `Quick
            test_prepared_absent_becomes_forensic
        ; test_case
            "bound stage is preserved"
            `Quick
            test_bound_stage_is_preserved
        ; test_case
            "allowed root identity mismatch is forensic"
            `Quick
            test_allowed_root_identity_mismatch_is_forensic
        ; test_case
            "corrupt and invalid rows block only owner"
            `Quick
            test_corrupt_and_invalid_rows_block_only_owner
        ; test_case
            "transition failure is explicit"
            `Quick
            test_transition_failure_is_explicit
        ; test_case
            "missing area preserves sources and continues inventory"
            `Quick
            test_missing_area_preserves_sources_and_continues_inventory
        ; test_case
            "counterpart area unavailable preserves prepared source"
            `Quick
            test_counterpart_area_unavailable_preserves_prepared_source
        ; test_case
            "unexpected lane entry is preserved and blocks owner"
            `Quick
            test_unexpected_lane_entry_is_preserved_and_blocks_owner
        ; test_case
            "wrong area permissions are not repaired"
            `Quick
            test_wrong_area_permissions_are_not_repaired
        ; test_case
            "existing registry permissions are not repaired"
            `Quick
            test_existing_registry_permissions_are_not_repaired
        ; test_case
            "existing lane permissions are not repaired"
            `Quick
            test_existing_lane_permissions_are_not_repaired
        ; test_case
            "structured report preserves corrupt evidence"
            `Quick
            test_structured_report_preserves_corrupt_evidence
        ] )
    ; ( "incremental recovery inventory"
      , [ test_case
            "exact demand reconciles without discovery"
            `Quick
            test_exact_demand_reconciles_without_discovery
        ; test_case
            "discovery does not prepopulate demand registry"
            `Quick
            test_discovery_does_not_prepopulate_demand_registry
        ; test_case
            "discovery suspension does not block exact demand"
            `Quick
            test_discovery_suspension_does_not_block_exact_demand
        ; test_case
            "suspended owner does not block unrelated owner"
            `Quick
            test_suspended_owner_does_not_block_unrelated_owner
        ; test_case
            "discovery failure is degraded and demand independent"
            `Quick
            test_discovery_failure_is_degraded_and_demand_independent
        ; test_case
            "non-current inventory cancellation is owner local"
            `Quick
            test_non_current_inventory_cancellation_is_owner_local
        ; test_case
            "non-current reconciliation cancellation is typed"
            `Quick
            test_non_current_reconciliation_cancellation_is_typed
        ; test_case
            "reconciliation crash is typed and owner local"
            `Quick
            test_reconciliation_crash_is_typed_and_owner_local
        ; test_case
            "discovery terminalizes after lock-wait cancellation"
            `Quick
            test_discovery_terminalizes_after_lock_wait_cancellation
        ; test_case
            "inspection progresses after lock-wait cancellation"
            `Quick
            test_inspection_progresses_after_lock_wait_cancellation
        ; test_case
            "reconciliation terminalizes after lock-wait cancellation"
            `Quick
            test_reconciliation_terminalizes_after_lock_wait_cancellation
        ; test_case
            "inventory generation reset race"
            `Quick
            test_inventory_generation_reset_race
        ; test_case
            "reconciliation generation reset race"
            `Quick
            test_reconciliation_generation_reset_race
        ; test_case
            "inspection winner cancellation does not strand waiters"
            `Quick
            test_waiter_progresses_when_inspection_winner_cancels_after_transition
        ; test_case
            "health aggregate counter transitions are checked"
            `Quick
            test_health_counter_transitions_are_checked
        ; test_case
            "retryable lane store health tracks exact owner"
            `Quick
            test_retryable_lane_store_health_tracks_exact_owner
        ; test_case
            "single borrow drains exactly once"
            `Quick
            test_single_borrow_drains_exactly_once
        ] )
    ]
;;
