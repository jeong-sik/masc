open Alcotest

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
    Fs_compat.open_publication_recovery_registry
      ~sw
      ~registry_root:Eio.Path.(fs / registry_root)
  with
  | Ok registry -> f registry
  | Error error ->
    fail (Fs_compat.publication_recovery_registry_error_to_string error)
;;

let require_fixture = function
  | Ok () -> ()
  | Error error ->
    fail (Fs_compat.publication_recovery_fixture_error_to_string error)
;;

let inventory_owner registry expected_name =
  let rows =
    match Fs_compat.inventory_publication_recovery_owners registry with
    | Ok rows -> rows
    | Error error ->
      fail
        (Fs_compat.publication_recovery_owner_inventory_error_to_string
           error)
  in
  match
    List.filter_map
      (function
        | Fs_compat.Publication_recovery_valid_owner owner
          when String.equal
                 (Fs_compat.publication_recovery_owner_to_string owner)
                 expected_name ->
          Some owner
        | Fs_compat.Publication_recovery_valid_owner _
        | Fs_compat.Publication_recovery_invalid_owner_name _
        | Fs_compat.Publication_recovery_unexpected_owner_kind _
        | Fs_compat.Publication_recovery_missing_owner_entry _
        | Fs_compat.Publication_recovery_owner_entry_unavailable _ -> None)
      rows
  with
  | [ owner ] -> owner
  | owners ->
    failf
      "expected exactly one owner %S, got %d"
      expected_name
      (List.length owners)
;;

let reconcile ~fs registry owner =
  match
    Fs_compat.reconcile_publication_recovery_owner
      ~fs
      ~registry
      ~owner
  with
  | Ok report -> report
  | Error error ->
    fail
      (Fs_compat.publication_recovery_reconciliation_error_to_string error)
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

let report_kinds report =
  Fs_compat.publication_recovery_reconciliation_report_row_kinds report
;;

let report_ready report =
  Fs_compat.publication_recovery_reconciliation_report_is_ready report
;;

let report_text report =
  Fs_compat.publication_recovery_reconciliation_report_to_string report
;;

(* The test intentionally pins the fixed layout documented by
   [Capability_recovery_obligation]; production traversal never reconstructs
   this path. *)
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
  (match
     Fs_compat.with_publication_recovery_lane
       ~registry
       ~owner:owner_name
       (fun _ -> ())
   with
   | Error error ->
     (match
        Fs_compat.publication_recovery_lane_reconciliation_error error
      with
      | Some
          (Fs_compat.Publication_recovery_reconciliation_required blocked) ->
        check string
          "exact pending owner"
          owner_name
          (Fs_compat.publication_recovery_owner_to_string blocked)
      | Some
          ( Fs_compat.Publication_recovery_reconciliation_in_progress _
          | Fs_compat.Publication_recovery_reconciliation_blocked _ )
      | None ->
        fail
          (Fs_compat.publication_recovery_lane_open_error_to_string error))
   | Ok () -> fail "pending owner was admitted before reconciliation");
  let report = reconcile ~fs registry owner in
  check bool "ready" true (report_ready report);
  (match report_kinds report with
   | [ Fs_compat.Publication_recovery_prepared_reconciled
         Fs_compat.Publication_recovery_prepared_unmaterialized ] -> ()
   | _ -> fail (report_text report));
  match
    Fs_compat.with_publication_recovery_lane
      ~registry
      ~owner:owner_name
      (fun _ -> ())
  with
  | Ok () -> ()
  | Error error ->
    fail (Fs_compat.publication_recovery_lane_open_error_to_string error)
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
  check bool
    "stage remains in target parent"
    true
    (Eio.Path.is_directory stage_path);
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
  let corrupt, invalid =
    List.fold_left
      (fun (corrupt, invalid) -> function
         | Fs_compat.Publication_recovery_corrupt_record_preserved ->
           true, invalid
         | Fs_compat.Publication_recovery_invalid_record_name -> corrupt, true
         | Fs_compat.Publication_recovery_prepared_reconciled _
         | Fs_compat.Publication_recovery_bound_reconciled _
         | Fs_compat.Publication_recovery_existing_forensic_record _
         | Fs_compat.Publication_recovery_unexpected_lane_entry
         | Fs_compat.Publication_recovery_missing_lane_entry
         | Fs_compat.Publication_recovery_lane_entry_unavailable
         | Fs_compat.Publication_recovery_area_inventory_unavailable
         | Fs_compat.Publication_recovery_source_transition_capabilities_unavailable
         | Fs_compat.Publication_recovery_conflicting_source_records
         | Fs_compat.Publication_recovery_unexpected_record_kind
         | Fs_compat.Publication_recovery_missing_record_entry
         | Fs_compat.Publication_recovery_record_entry_unavailable
         | Fs_compat.Publication_recovery_record_observation_failed
         | Fs_compat.Publication_recovery_record_transition_failed
         | Fs_compat.Publication_recovery_record_scope_release_failed
         | Fs_compat.Publication_recovery_owner_store_release_failed
         | Fs_compat.Publication_recovery_owner_store_unavailable
         | Fs_compat.Publication_recovery_owner_inventory_unavailable ->
           corrupt, invalid)
      (false, false)
      (report_kinds report)
  in
  check bool "corrupt row explicit" true corrupt;
  check bool "invalid row explicit" true invalid;
  (match
     Fs_compat.with_publication_recovery_lane
       ~registry
       ~owner:owner_name
       (fun _ -> ())
   with
   | Error error ->
     (match
        Fs_compat.publication_recovery_lane_reconciliation_error error
      with
      | Some (Fs_compat.Publication_recovery_reconciliation_blocked _) -> ()
      | Some
          ( Fs_compat.Publication_recovery_reconciliation_required _
          | Fs_compat.Publication_recovery_reconciliation_in_progress _ )
      | None ->
        fail
          (Fs_compat.publication_recovery_lane_open_error_to_string error))
   | Ok () -> fail "blocked owner was admitted");
  match
    Fs_compat.with_publication_recovery_lane
      ~registry
      ~owner:"unrelated-owner"
      (fun _ -> ())
  with
  | Ok () -> ()
  | Error error ->
    failf
      "unrelated owner was blocked: %s"
      (Fs_compat.publication_recovery_lane_open_error_to_string error)
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
    (List.exists
       (function
         | Fs_compat.Publication_recovery_record_transition_failed -> true
         | Fs_compat.Publication_recovery_prepared_reconciled _
         | Fs_compat.Publication_recovery_bound_reconciled _
         | Fs_compat.Publication_recovery_existing_forensic_record _
         | Fs_compat.Publication_recovery_unexpected_lane_entry
         | Fs_compat.Publication_recovery_missing_lane_entry
         | Fs_compat.Publication_recovery_lane_entry_unavailable
         | Fs_compat.Publication_recovery_area_inventory_unavailable
         | Fs_compat.Publication_recovery_source_transition_capabilities_unavailable
         | Fs_compat.Publication_recovery_conflicting_source_records
         | Fs_compat.Publication_recovery_invalid_record_name
         | Fs_compat.Publication_recovery_unexpected_record_kind
         | Fs_compat.Publication_recovery_missing_record_entry
         | Fs_compat.Publication_recovery_record_entry_unavailable
         | Fs_compat.Publication_recovery_corrupt_record_preserved
         | Fs_compat.Publication_recovery_record_observation_failed
         | Fs_compat.Publication_recovery_record_scope_release_failed
         | Fs_compat.Publication_recovery_owner_store_release_failed
         | Fs_compat.Publication_recovery_owner_store_unavailable
         | Fs_compat.Publication_recovery_owner_inventory_unavailable -> false)
       (report_kinds report))
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
  let forensic_path =
    owner_area_path ~registry_root ~owner:owner_name "forensic"
  in
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
  let recovery_root =
    Filename.concat registry_root "fs-publication-recovery"
  in
  Unix.chmod recovery_root 0o750;
  let result =
    Eio.Switch.run @@ fun sw ->
    Fs_compat.open_publication_recovery_registry
      ~sw
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

let test_exact_owner_await_resolves_after_reconciliation () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "await-ready-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "99999999-9999-4999-8999-999999999999")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inventory_owner registry owner_name in
  let waiter_started, resolve_waiter_started = Eio.Promise.create () in
  let waiter_result, resolve_waiter_result = Eio.Promise.create () in
  Eio.Fiber.both
    (fun () ->
       Eio.Promise.resolve resolve_waiter_started ();
       Eio.Promise.resolve
         resolve_waiter_result
         (Fs_compat.await_publication_recovery_lane_reconciliation
            ~registry
            ~owner:owner_name))
    (fun () ->
       Eio.Promise.await waiter_started;
       check bool
         "pending owner await is suspended"
         true
         (Option.is_none (Eio.Promise.peek waiter_result));
       let report = reconcile ~fs registry owner in
       check bool "reconciled owner ready" true (report_ready report));
  match Eio.Promise.await waiter_result with
  | Ok () -> ()
  | Error error ->
    fail
      (Fs_compat.publication_recovery_lane_open_error_to_string error)
;;

let test_single_borrow_drains_exactly_once () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "single-borrow-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inventory_owner registry owner_name in
  let report = reconcile ~fs registry owner in
  check bool "owner ready before borrow" true (report_ready report);
  match
    Fs_compat.Capability_write_for_testing.single_publication_recovery_borrow_balance
      ~registry
      ~owner:owner_name
  with
  | Ok
      (Fs_compat.Capability_write_for_testing.Single_borrow_balance
        { during_borrow; after_release; close_completed }) ->
    check int "one borrow increments once" 1 during_borrow;
    check int "one release drains to zero" 0 after_release;
    check bool "zero-count close completes" true close_completed
  | Ok Fs_compat.Capability_write_for_testing.Single_borrow_rejected ->
    fail "fresh open access rejected its first borrow"
  | Ok (Fs_compat.Capability_write_for_testing.Single_borrow_invariant _) ->
    fail "fresh single borrow reached an invariant violation"
  | Ok (Fs_compat.Capability_write_for_testing.Single_borrow_raised failure) ->
    failf
      "fresh single borrow raised: %s"
      (Printexc.to_string failure.exception_)
  | Error error ->
    fail
      (Fs_compat.publication_recovery_lane_open_error_to_string error)
;;

let test_live_context_cancellation_is_terminal_and_typed () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "live-cancelled-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inventory_owner registry owner_name in
  let reason = Failure "deterministic live-context cancellation" in
  (match
     Fs_compat.Capability_write_for_testing.interrupt_publication_recovery_reconciliation
       ~fs
       ~registry
       ~owner
       (Fs_compat.Capability_write_for_testing.Cancel_reconciliation reason)
   with
   | exception Eio.Cancel.Cancelled observed ->
     check bool "original cancellation reason" true (observed == reason)
   | Ok _ -> fail "cancelled reconciliation returned a report"
   | Error error ->
     fail
       (Fs_compat.publication_recovery_reconciliation_error_to_string error));
  (match
     Fs_compat.Capability_write_for_testing.publication_recovery_owner_settlement
       ~registry
       ~owner
   with
   | Fs_compat.Capability_write_for_testing.Owner_settled -> ()
   | Fs_compat.Capability_write_for_testing.Owner_untracked
   | Fs_compat.Capability_write_for_testing.Owner_unsettled ->
     fail "live-context cancellation did not settle its exact owner");
  (match
     Fs_compat.await_publication_recovery_lane_reconciliation
       ~registry
       ~owner:owner_name
   with
   | Error error ->
     (match
        Fs_compat.publication_recovery_lane_reconciliation_error error
      with
      | Some
          (Fs_compat.Publication_recovery_reconciliation_blocked
            (Fs_compat.Publication_recovery_owner_cancelled_block
              { owner = blocked_owner; reason = blocked_reason; _ })) ->
        check string
          "exact cancelled owner"
          owner_name
          (Fs_compat.publication_recovery_owner_to_string blocked_owner);
        check bool "exact cancellation reason" true (blocked_reason == reason)
      | Some
          ( Fs_compat.Publication_recovery_reconciliation_required _
          | Fs_compat.Publication_recovery_reconciliation_in_progress _
          | Fs_compat.Publication_recovery_reconciliation_blocked
              ( Fs_compat.Publication_recovery_owner_inventory_block _
              | Fs_compat.Publication_recovery_owner_report_block _
              | Fs_compat.Publication_recovery_owner_crash_block _
              | Fs_compat.Publication_recovery_owner_activation_rejected_block _ ) )
      | None ->
        fail
          (Fs_compat.publication_recovery_lane_open_error_to_string error))
   | Ok () -> fail "live-context cancelled owner was admitted");
  match
    Fs_compat.reconcile_publication_recovery_owner ~fs ~registry ~owner
  with
  | Error
      (Fs_compat.Publication_recovery_owner_reconciliation_cancelled
        { owner = cancelled_owner; reason = cancelled_reason; _ }) ->
    check string
      "terminal cancelled owner"
      owner_name
      (Fs_compat.publication_recovery_owner_to_string cancelled_owner);
    check bool "terminal cancellation reason" true (cancelled_reason == reason)
  | Error error ->
    fail
      (Fs_compat.publication_recovery_reconciliation_error_to_string error)
  | Ok _ -> fail "live-context cancelled owner was silently retried"
;;

let test_parent_cancellation_returns_owner_to_pending () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "parent-cancelled-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inventory_owner registry owner_name in
  let reason = Failure "deterministic parent cancellation" in
  (match
     Eio.Cancel.sub @@ fun context ->
     Eio.Cancel.cancel context reason;
     Fs_compat.Capability_write_for_testing.interrupt_publication_recovery_reconciliation
       ~fs
       ~registry
       ~owner
       (Fs_compat.Capability_write_for_testing.Cancel_reconciliation reason)
   with
   | exception Eio.Cancel.Cancelled observed ->
     check bool "original parent cancellation reason" true (observed == reason)
   | Ok _ -> fail "parent-cancelled reconciliation returned a report"
   | Error error ->
     fail
       (Fs_compat.publication_recovery_reconciliation_error_to_string error));
  (match
     Fs_compat.Capability_write_for_testing.publication_recovery_owner_settlement
       ~registry
       ~owner
   with
   | Fs_compat.Capability_write_for_testing.Owner_unsettled -> ()
   | Fs_compat.Capability_write_for_testing.Owner_untracked
   | Fs_compat.Capability_write_for_testing.Owner_settled ->
     fail "parent cancellation incorrectly settled its exact owner");
  let waiter_started, resolve_waiter_started = Eio.Promise.create () in
  let waiter_result, resolve_waiter_result = Eio.Promise.create () in
  Eio.Fiber.both
    (fun () ->
       Eio.Promise.resolve resolve_waiter_started ();
       Eio.Promise.resolve
         resolve_waiter_result
         (Fs_compat.await_publication_recovery_lane_reconciliation
            ~registry
            ~owner:owner_name))
    (fun () ->
       Eio.Promise.await waiter_started;
       check bool
         "parent-cancelled owner await remains suspended"
         true
         (Option.is_none (Eio.Promise.peek waiter_result));
       let report = reconcile ~fs registry owner in
       check bool "retry reaches terminal ready" true (report_ready report));
  match Eio.Promise.await waiter_result with
  | Ok () -> ()
  | Error error ->
    fail
      (Fs_compat.publication_recovery_lane_open_error_to_string error)
;;

let test_activation_rejection_terminally_blocks_exact_owner () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "activation-rejected-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "ffffffff-ffff-4fff-8fff-ffffffffffff")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inventory_owner registry owner_name in
  (match
     Fs_compat.reject_publication_recovery_owner_activation
       ~registry
       ~owner
   with
   | Ok () -> ()
   | Error error ->
     fail
       (Fs_compat.publication_recovery_activation_rejection_error_to_string
          error));
  (match
     Fs_compat.Capability_write_for_testing.publication_recovery_owner_settlement
       ~registry
       ~owner
   with
   | Fs_compat.Capability_write_for_testing.Owner_settled -> ()
   | Fs_compat.Capability_write_for_testing.Owner_untracked
   | Fs_compat.Capability_write_for_testing.Owner_unsettled ->
     fail "activation rejection did not settle its exact owner");
  (match
     Fs_compat.await_publication_recovery_lane_reconciliation
       ~registry
       ~owner:owner_name
   with
   | Error error ->
     (match
        Fs_compat.publication_recovery_lane_reconciliation_error error
      with
      | Some
          (Fs_compat.Publication_recovery_reconciliation_blocked
            (Fs_compat.Publication_recovery_owner_activation_rejected_block
              blocked_owner)) ->
        check string
          "exact activation-rejected owner"
          owner_name
          (Fs_compat.publication_recovery_owner_to_string blocked_owner)
      | Some
          ( Fs_compat.Publication_recovery_reconciliation_required _
          | Fs_compat.Publication_recovery_reconciliation_in_progress _
          | Fs_compat.Publication_recovery_reconciliation_blocked
              ( Fs_compat.Publication_recovery_owner_inventory_block _
              | Fs_compat.Publication_recovery_owner_report_block _
              | Fs_compat.Publication_recovery_owner_crash_block _
              | Fs_compat.Publication_recovery_owner_cancelled_block _ ) )
      | None ->
        fail
          (Fs_compat.publication_recovery_lane_open_error_to_string error))
   | Ok () -> fail "activation-rejected owner was admitted");
  match
    Fs_compat.reconcile_publication_recovery_owner ~fs ~registry ~owner
  with
  | Error (Fs_compat.Publication_recovery_owner_activation_rejected rejected) ->
    check string
      "reconciliation remains terminally rejected"
      owner_name
      (Fs_compat.publication_recovery_owner_to_string rejected)
  | Error error ->
    fail
      (Fs_compat.publication_recovery_reconciliation_error_to_string error)
  | Ok _ -> fail "activation-rejected owner was silently reconciled"
;;

let test_crashed_reconciliation_is_terminal_and_typed () =
  with_tmp_dir @@ fun temp_root ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let allowed_root_path = Unix.realpath temp_root in
  let root = Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path) in
  let registry_root = Filename.concat temp_root "registry" in
  Unix.mkdir registry_root 0o700;
  let owner_name = "crashed-owner" in
  with_registry ~fs ~registry_root @@ fun registry ->
  seed_prepared
    ~registry
    ~owner:owner_name
    ~operation_id:(operation_id "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    ~allowed_root_path
    ~allowed_root_device:root.dev
    ~allowed_root_inode:root.ino;
  let owner = inventory_owner registry owner_name in
  let crash = Failure "deterministic reconciliation crash" in
  (match
     Fs_compat.Capability_write_for_testing.interrupt_publication_recovery_reconciliation
       ~fs
       ~registry
       ~owner
       (Fs_compat.Capability_write_for_testing.Crash_reconciliation crash)
   with
   | exception observed when observed == crash -> ()
   | exception observed ->
     failf "unexpected crash propagated: %s" (Printexc.to_string observed)
   | Ok _ -> fail "crashed reconciliation returned a report"
   | Error error ->
     fail
       (Fs_compat.publication_recovery_reconciliation_error_to_string error));
  (match
     Fs_compat.await_publication_recovery_lane_reconciliation
       ~registry
       ~owner:owner_name
   with
   | Error error ->
     (match
        Fs_compat.publication_recovery_lane_reconciliation_error error
      with
      | Some
          (Fs_compat.Publication_recovery_reconciliation_blocked
            (Fs_compat.Publication_recovery_owner_crash_block
              { owner = blocked_owner; exception_; _ })) ->
        check string
          "exact crashed owner"
          owner_name
          (Fs_compat.publication_recovery_owner_to_string blocked_owner);
        check bool "exact crash retained" true (exception_ == crash)
      | Some
          ( Fs_compat.Publication_recovery_reconciliation_required _
          | Fs_compat.Publication_recovery_reconciliation_in_progress _
          | Fs_compat.Publication_recovery_reconciliation_blocked
              ( Fs_compat.Publication_recovery_owner_inventory_block _
              | Fs_compat.Publication_recovery_owner_report_block _
              | Fs_compat.Publication_recovery_owner_cancelled_block _
              | Fs_compat.Publication_recovery_owner_activation_rejected_block _ ) )
      | None ->
        fail
          (Fs_compat.publication_recovery_lane_open_error_to_string error))
   | Ok () -> fail "crashed owner was admitted");
  match
    Fs_compat.reconcile_publication_recovery_owner ~fs ~registry ~owner
  with
  | Error
      (Fs_compat.Publication_recovery_owner_reconciliation_crashed
        { owner = crashed_owner; exception_; _ }) ->
    check string
      "terminal error owner"
      owner_name
      (Fs_compat.publication_recovery_owner_to_string crashed_owner);
    check bool "terminal error retains crash" true (exception_ == crash)
  | Error error ->
    fail
      (Fs_compat.publication_recovery_reconciliation_error_to_string error)
  | Ok _ -> fail "crashed owner reconciliation was silently retried"
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

let () =
  run
    "fs_compat publication reconciliation"
    [ ( "startup reconciliation"
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
            "exact owner await resolves after reconciliation"
            `Quick
            test_exact_owner_await_resolves_after_reconciliation
        ; test_case
            "single borrow drains exactly once"
            `Quick
            test_single_borrow_drains_exactly_once
        ; test_case
            "live-context cancellation is terminal and typed"
            `Quick
            test_live_context_cancellation_is_terminal_and_typed
        ; test_case
            "parent cancellation returns owner to pending"
            `Quick
            test_parent_cancellation_returns_owner_to_pending
        ; test_case
            "activation rejection terminally blocks exact owner"
            `Quick
            test_activation_rejection_terminally_blocks_exact_owner
        ; test_case
            "crashed reconciliation is terminal and typed"
            `Quick
            test_crashed_reconciliation_is_terminal_and_typed
        ; test_case
            "structured report preserves corrupt evidence"
            `Quick
            test_structured_report_preserves_corrupt_evidence
        ] )
    ]
;;
