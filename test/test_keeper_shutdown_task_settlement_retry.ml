open Alcotest
open Masc
open Keeper_shutdown_types
module Retry = Keeper_shutdown_task_settlement_retry
module Store = Keeper_shutdown_store

let () = Mirage_crypto_rng_unix.use_default ()
let require error = function Ok value -> value | Error value -> fail (error value)
let store result = require Store.error_to_string result
let task result = require Masc_domain.masc_error_to_string result
let read config = require Fun.id (Workspace_backlog.read_backlog_r config)
let load config operation = store (Store.load ~config ~keeper_name:operation.keeper_name operation.operation_id)

let rec remove_tree path = match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_fixture ?(claimed = 1) ?(owner_trace = "retry-original-trace") f =
  let base_path = Filename.temp_dir "shutdown-task-settlement-retry" "" in
  Fun.protect ~finally:(fun () -> Keeper_shutdown_intake_fence.For_testing.reset (); remove_tree base_path)
    (fun () -> Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Fun.protect ~finally:Fs_compat.clear_fs (fun () -> Eio.Switch.run @@ fun sw ->
        let config = Workspace.default_config base_path in
        ignore (Workspace.init config ~agent_name:None);
        ignore (require Keeper_owner_registry.install_error_to_string
          (Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config));
        let keeper_name = "retry-owner" in
        let meta = require Fun.id (Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String keeper_name; "trace_id", `String owner_trace ])) in
        ignore (require Keeper_owner_registry.command_error_to_string
          (Keeper_owner_registry.create_meta ~base_path meta));
        let ids = List.init claimed (fun index ->
          ignore (Workspace.add_task config ~title:"Retained work" ~priority:1 ~description:"");
          let id = Printf.sprintf "task-%03d" (index + 1) in
          ignore (task (Workspace.claim_task_r config ~agent_name:keeper_name ~task_id:id ()));
          require Fun.id (Keeper_id.Task_id.of_string id)) in
        let operation = { schema_version; revision = 1; operation_id = Operation_id.generate ()
          ; keeper_name; lane_ownership = Dormant_meta
          ; trace_id = require Fun.id (Keeper_id.Trace_id.of_string "retry-original-trace")
          ; actor = "original-purge-operator"
          ; cleanup_intent = { reason = Dashboard_keeper_purge { requested_name = keeper_name }; remove_session = true }
          ; turn_disposition = No_inflight_turn; expected_backlog_version = (read config).version
          ; owned_task_ids = ids; join_evidence = None
          ; phase = Blocked { stage = Task_settlement; detail = "retained pre-fix refusal; text is not authority" }
          ; created_at = "2026-11-10T00:00:00Z"; updated_at = "2026-11-10T00:00:00Z" } in
        store (Store.persist_new ~config operation);
        ignore (require Keeper_owner_registry.command_error_to_string
          (Keeper_owner_registry.restore_shutdown ~base_path ~keeper_name ~operation_id:operation.operation_id));
        (match Keeper_shutdown_intake_fence.restore_shutdown ~base_path ~keeper_name ~operation_id:operation.operation_id with
         | Restored | Already_restored -> () | Restore_conflict _ -> fail "fixture fence conflict");
        f ~config ~operation))
;;

let prepare config operation = Retry.prepare ~config ~keeper_name:operation.keeper_name
  ~operation_id:operation.operation_id ~expected_revision:operation.revision
  ~expected_backlog_version:(read config).version
;;

let assert_refused_unchanged ~config ~operation predicate result =
  (match result with Error error when predicate error -> ()
   | Error error -> fail (Retry.error_to_string error) | Ok _ -> fail "unsafe retry was prepared");
  check bool "refusal retains the exact operation" true (load config operation = operation)
;;

let test_explicit_prepare_preserves_tasks_and_original_intent () =
  with_fixture (fun ~config ~operation ->
    let before = read config in
    let canonical = Fs_compat.load_file (Workspace_backlog.backlog_path config) in
    let preview = require Retry.error_to_string
      (Retry.preview ~config ~keeper_name:operation.keeper_name ~operation_id:operation.operation_id) in
    check bool "preview is observational" true (load config operation = operation);
    check int "preview binds authoritative version" before.version preview.backlog_version;
    let prepared = require Retry.error_to_string (prepare config operation) in
    check bool "original actor, intent, identity and task IDs are immutable" true
      (immutable_fields_equal operation prepared);
    check int "one exact revision commits" (operation.revision + 1) prepared.revision;
    (match prepared.phase with Finalizing_tasks [] -> () | _ -> fail "unreleased Task was marked receipted");
    check bool "canonical Task ownership is unchanged by preparation" true (read config = before);
    check string "canonical bytes remain unchanged" canonical
      (Fs_compat.load_file (Workspace_backlog.backlog_path config));
    check bool "preparation retains the original admission fence" true
      (match Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path:config.base_path ~keeper_name:operation.keeper_name with
       | Some id -> Operation_id.equal id operation.operation_id | None -> false);
    assert_refused_unchanged ~config ~operation:prepared
      (function Retry.Store_error (Store.Revision_conflict _) -> true | _ -> false)
      (prepare config operation))
;;

let release ~config operation id receipt =
  let handoff_context : Masc_domain.task_handoff_context =
    { summary = "Return retained work"; reason = None; next_step = None; failure_mode = None
    ; evidence_refs = [receipt]; updated_at = None; updated_by = None } in
  ignore (task (Workspace.release_task_r config ~agent_name:operation.keeper_name
    ~task_id:(Keeper_id.Task_id.to_string id) ~handoff_context ()))
;;

let test_exact_receipts_and_foreign_ownership () =
  with_fixture ~claimed:2 (fun ~config ~operation ->
    let first = List.hd operation.owned_task_ids in
    release ~config operation first ("masc://keeper-shutdown/" ^ Operation_id.to_string operation.operation_id);
    let before = read config in
    let prepared = require Retry.error_to_string (prepare config operation) in
    (match prepared.phase with
     | Finalizing_tasks [id] when Keeper_id.Task_id.equal id first -> ()
     | _ -> fail "only the exact operation receipt must be retained");
    check bool "mixed receipted/owned Tasks are not mutated" true (read config = before));
  with_fixture (fun ~config ~operation ->
    let id = List.hd operation.owned_task_ids in
    release ~config operation id ("masc://keeper-shutdown/" ^ Operation_id.to_string (Operation_id.generate ()));
    assert_refused_unchanged ~config ~operation (function Retry.Recorded_task_changed _ -> true | _ -> false)
      (prepare config operation);
    ignore (task (Workspace.claim_task_r config ~agent_name:"another-owner" ~task_id:(Keeper_id.Task_id.to_string id) ()));
    let before = read config in
    assert_refused_unchanged ~config ~operation (function Retry.Recorded_task_changed _ -> true | _ -> false)
      (prepare config operation);
    check bool "another owner's task cannot be stolen" true (read config = before))
;;

let test_versions_and_precommit_race () =
  with_fixture (fun ~config ~operation ->
    assert_refused_unchanged ~config ~operation (function Retry.Store_error (Store.Revision_conflict _) -> true | _ -> false)
      (Retry.prepare ~config ~keeper_name:operation.keeper_name ~operation_id:operation.operation_id
        ~expected_revision:0 ~expected_backlog_version:(read config).version);
    let version = (read config).version in
    let result = Retry.For_testing.prepare ~config ~keeper_name:operation.keeper_name
      ~operation_id:operation.operation_id ~expected_revision:operation.revision ~expected_backlog_version:version
      ~on_guards_acquired:(fun () -> ignore (Workspace.add_task config ~title:"Concurrent backlog change" ~priority:1 ~description:"")) in
    assert_refused_unchanged ~config ~operation (function Retry.Backlog_revision_conflict _ -> true | _ -> false) result);
  with_fixture (fun ~config ~operation ->
    let sibling = { operation with operation_id = Operation_id.generate (); owned_task_ids = []
      ; created_at = "2026-11-10T00:00:01Z"; updated_at = "2026-11-10T00:00:01Z" } in
    let result = Retry.For_testing.prepare ~config ~keeper_name:operation.keeper_name
      ~operation_id:operation.operation_id ~expected_revision:operation.revision
      ~expected_backlog_version:(read config).version
      ~on_guards_acquired:(fun () -> store (Store.persist_new ~config sibling)) in
    assert_refused_unchanged ~config ~operation (function Retry.Conflicting_sibling _ -> true | _ -> false) result)
;;

let test_trace_fence_inventory_and_new_tasks () =
  with_fixture ~owner_trace:"a-later-owner-trace" (fun ~config ~operation ->
    assert_refused_unchanged ~config ~operation (function Retry.Owner_trace_changed -> true | _ -> false)
      (prepare config operation));
  with_fixture (fun ~config ~operation ->
    ignore (Keeper_shutdown_intake_fence.transition_shutdown ~base_path:config.base_path ~keeper_name:operation.keeper_name
      ~from_operation_id:operation.operation_id ~to_operation_id:(Some (Operation_id.generate ())));
    assert_refused_unchanged ~config ~operation (function Retry.Admission_mismatch -> true | _ -> false)
      (prepare config operation));
  with_fixture (fun ~config ~operation ->
    ignore (Workspace.add_task config ~title:"New owned work" ~priority:1 ~description:"");
    ignore (task (Workspace.claim_task_r config ~agent_name:operation.keeper_name ~task_id:"task-002" ()));
    assert_refused_unchanged ~config ~operation (function Retry.New_owned_tasks ["task-002"] -> true | _ -> false)
      (prepare config operation));
  with_fixture (fun ~config ~operation ->
    let other = Operation_id.generate () in
    let path = store (Store.path ~config ~keeper_name:operation.keeper_name other) in
    Fs_compat.save_file path "{invalid shutdown record";
    assert_refused_unchanged ~config ~operation (function Retry.Corrupt_sibling _ -> true | _ -> false)
      (prepare config operation));
  with_fixture (fun ~config ~operation ->
    Fs_compat.save_file (Workspace_backlog.backlog_path config) "{invalid canonical backlog";
    assert_refused_unchanged ~config ~operation (function Retry.Backlog_unavailable _ -> true | _ -> false)
      (Retry.prepare ~config ~keeper_name:operation.keeper_name ~operation_id:operation.operation_id
        ~expected_revision:operation.revision ~expected_backlog_version:operation.expected_backlog_version))
;;

let test_only_explicit_task_stage_is_eligible () =
  with_fixture ~claimed:0 (fun ~config ~operation ->
    check bool "blocked Task settlement has no boot replay" true (Option.is_none (boot_replay operation));
    check bool "exact retained case is eligible" true (Store.task_settlement_retry_eligible operation);
    List.iter (fun phase ->
      let changed = { operation with phase } in
      check bool "other phases have no operator task-retry authority" false
        (Store.task_settlement_retry_eligible changed))
      [ Blocked { stage = Turn_join; detail = "not a task refusal" }; Joined_idle; Finalizing_tasks [] ];
    check bool "a registered lane is excluded" false
      (Store.task_settlement_retry_eligible { operation with lane_ownership = Registered_lane
        (require Fun.id (Keeper_lane.Id.of_string "lane-00000000-0000-4000-8000-000000000001")) });
    check bool "preview never advances durable operation" true (load config operation = operation))
;;

let test_live_owner_child_and_registered_lane_are_refused () =
  with_fixture ~claimed:0 (fun ~config ~operation ->
    let owner = require Keeper_owner_registry.lookup_error_to_string
      (Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name:operation.keeper_name) in
    ignore (require Keeper_owner.error_to_string (Keeper_owner.transition_shutdown owner
      ~from_operation_id:operation.operation_id ~to_operation_id:None));
    Eio.Switch.run @@ fun sw ->
    let started, start = Eio.Promise.create () in
    let release, finish = Eio.Promise.create () in
    let ended = Eio.Stream.create 1 in
    Eio.Fiber.fork ~sw (fun () ->
      let result = Keeper_owner.run_autonomous_if_idle owner (fun () ->
        Eio.Promise.resolve start (); Eio.Promise.await release) in
      Eio.Stream.add ended result);
    Eio.Promise.await started;
    ignore (require Keeper_owner.error_to_string
      (Keeper_owner.restore_shutdown owner ~operation_id:operation.operation_id));
    Fun.protect ~finally:(fun () -> Eio.Promise.resolve finish ()) (fun () ->
      assert_refused_unchanged ~config ~operation (function Retry.Owner_turn_present -> true | _ -> false)
        (prepare config operation));
    ignore (Eio.Stream.take ended));
  with_fixture ~claimed:0 (fun ~config ~operation ->
    let owner = require Keeper_owner_registry.lookup_error_to_string
      (Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name:operation.keeper_name) in
    let meta = match (Keeper_owner.projection owner).meta with
      | Some meta -> meta | None -> fail "fixture metadata is absent" in
    let entry = Keeper_registry.register_offline ~base_path:config.base_path operation.keeper_name meta in
    Fun.protect ~finally:(fun () -> ignore (Keeper_registry.unregister_exact entry)) (fun () ->
      assert_refused_unchanged ~config ~operation (function Retry.Registry_lane_present -> true | _ -> false)
        (prepare config operation)))
;;

let () = run "explicit blocked task-settlement retry"
  [ "real temporary stores", [ test_case "prepare only, exact identity and no Task effects" `Quick test_explicit_prepare_preserves_tasks_and_original_intent
    ; test_case "exact receipts and foreign ownership" `Quick test_exact_receipts_and_foreign_ownership
    ; test_case "revision and sibling races" `Quick test_versions_and_precommit_race
    ; test_case "trace fence unread state and new ownership" `Quick test_trace_fence_inventory_and_new_tasks
    ; test_case "actual Owner child and registry membership" `Quick test_live_owner_child_and_registered_lane_are_refused
    ; test_case "narrow explicit recovery boundary" `Quick test_only_explicit_task_stage_is_eligible ] ]
