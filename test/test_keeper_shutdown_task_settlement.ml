open Alcotest
open Masc
open Keeper_shutdown_types

let cleanup_dir path =
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | { Unix.st_kind =
          (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK)
      ; _ } -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  remove path
;;

let with_workspace f =
  let base = Filename.temp_file "shutdown-task-cas-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    (* Stop after real Task settlement, before any sandbox or identity cleanup.
       This existing boundary needs no new production observer or test hook. *)
    Keeper_shutdown_finalize.register_remove_pending_confirms_by_target
      (fun _ ~target_type:_ ~target_id:_ -> Error "fixture stops before identity cleanup");
    Fun.protect
      ~finally:(fun () ->
        Keeper_shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
        Fs_compat.clear_fs ())
      (fun () ->
        let config = Workspace.default_config base in
        ignore (Workspace.init config ~agent_name:None);
        Eio.Switch.run @@ fun sw ->
        (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
                 ~on_turn_slot_released:None config with
         | Ok 0 -> ()
         | Ok _ -> fail "fixture unexpectedly loaded owners"
         | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
        f config))
;;

let require_task = function
  | Ok value -> value
  | Error error -> fail (Masc_domain.masc_error_to_string error)
;;

let read_backlog config =
  match Workspace_backlog.read_backlog_r config with
  | Ok backlog -> backlog
  | Error detail -> fail detail
;;

let task config id =
  match List.find_opt (fun (task : Masc_domain.task) -> task.id = id)
          (read_backlog config).tasks with
  | Some task -> task
  | None -> fail ("missing fixture Task " ^ id)
;;

let add_task config title =
  match Workspace.add_task_with_result config ~title ~priority:1 ~description:"fixture" with
  | Ok added -> added.task_id
  | Error error -> fail (Workspace.add_task_error_to_string error)
;;

let claim config owner id =
  ignore (require_task (Workspace.claim_task_r config ~agent_name:owner ~task_id:id ()))
;;

let check_claimed config id owner =
  match (task config id).task_status with
  | Masc_domain.Claimed { assignee; _ } -> check string "Task owner" owner assignee
  | Masc_domain.Todo | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
  | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "Task ownership changed"
;;

let check_todo config id =
  match (task config id).task_status with
  | Masc_domain.Todo -> ()
  | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
  | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "owned Task was not released"
;;

let receipt_ref operation = "masc://keeper-shutdown/" ^ Operation_id.to_string operation.operation_id

let handoff evidence : Masc_domain.task_handoff_context =
  { summary = "retain this Task's handoff"
  ; reason = Some "fixture release"
  ; next_step = Some "continue the original work"
  ; failure_mode = None
  ; evidence_refs = [evidence]
  ; updated_at = Some (Masc_domain.now_iso ())
  ; updated_by = Some "fixture"
  }
;;

let operation config =
  let keeper_name = "shutdown-cas-fixture" in
  let meta =
    match Masc_test_deps.meta_of_json_fixture
            (`Assoc ["name", `String keeper_name;
                     "trace_id", `String "trace-shutdown-cas-fixture"]) with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  (match Keeper_owner_registry.create_meta ~base_path:config.Workspace.base_path meta with
   | Ok (Some _) -> ()
   | Ok None -> fail "fixture metadata disappeared"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  let first = add_task config "first owned Task" in
  let second = add_task config "second owned Task" in
  claim config keeper_name first;
  claim config keeper_name second;
  let task_id id =
    match Keeper_id.Task_id.of_string id with
    | Ok id -> id
    | Error detail -> fail detail
  in
  let operation =
    { schema_version = Keeper_shutdown_types.schema_version
    ; revision = 1
    ; operation_id = Operation_id.generate ()
    ; keeper_name
    ; lane_ownership = Dormant_meta
    ; trace_id = meta.runtime.trace_id
    ; actor = "fixture-operator"
    ; cleanup_intent = { reason = Operator_stop_retain_meta; remove_session = false }
    ; turn_disposition = No_inflight_turn
    ; expected_backlog_version = (read_backlog config).version
    ; owned_task_ids = List.map task_id [first; second]
    ; join_evidence = None
    ; phase = Joined_idle
    ; created_at = Masc_domain.now_iso ()
    ; updated_at = Masc_domain.now_iso ()
    }
  in
  (match Keeper_shutdown_store.persist_new ~config operation with
   | Ok () -> ()
   | Error error -> fail (Keeper_shutdown_store.error_to_string error));
  operation, first, second
;;

let stopped_operation ~config ~stage operation =
  let stopped =
    match Keeper_shutdown_finalize.run ~config ~entry:None operation with
    | Error (Keeper_shutdown_finalize.Finalization_blocked stopped) -> stopped
    | Error ((Keeper_shutdown_finalize.Store_error _ | Unsupported_phase
             | Finalization_draining _ | Completion_failed _ | Admission_release_failed _) as error) ->
      fail (Keeper_shutdown_finalize.error_to_string error)
    | Ok _ -> fail "fixture reached identity cleanup"
  in
  (match stopped.phase with
   | Blocked failure -> check bool "stopped at the intended stage" true (failure.stage = stage)
   | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _ | Cleanup_ready _
   | Reconciliation_required _ | Finalized _ | Owner_absent _
   | Operator_absence_acknowledged _ | Superseded _ -> fail "missing durable stop");
  let durable =
    match Keeper_shutdown_store.load ~config ~keeper_name:operation.keeper_name
            operation.operation_id with
    | Ok durable -> durable
    | Error error -> fail (Keeper_shutdown_store.error_to_string error)
  in
  check int "operation journal revision persisted" stopped.revision durable.revision;
  check int "backlog progress persisted separately" stopped.expected_backlog_version
    durable.expected_backlog_version;
  durable
;;

let check_receipt config operation id =
  check_todo config id;
  match (task config id).handoff_context with
  | Some context ->
    check bool "release belongs to this operation" true
      (List.mem (receipt_ref operation) context.evidence_refs)
  | None -> fail "released Task lost its durable receipt"
;;

let test_typed_cas_and_authoritative_reobservation () = with_workspace (fun config ->
  let operation, first, second = operation config in
  let unrelated = add_task config "another owner's Task" in
  claim config "other-owner" unrelated;
  let actual = (read_backlog config).version in
  (match Workspace.release_task_r config ~agent_name:operation.keeper_name ~task_id:first
           ~expected_version:operation.expected_backlog_version
           ~handoff_context:(handoff (receipt_ref operation)) () with
   | Error (Masc_domain.Task
              (Masc_domain.Task_error.BacklogVersionConflict conflict) as error) ->
     check int "expected version is the frozen Task observation"
       operation.expected_backlog_version conflict.expected;
     check int "actual version was read under the backlog lock" actual conflict.actual;
     check int "HTTP contract stays unchanged" 400 (Masc_error.code error);
     check bool "generic replay remains disabled" false (Masc_error.is_retryable error)
   | Error ((Masc_domain.Task
               (Masc_domain.Task_error.NotFound _ | AlreadyClaimed _ | InvalidState _
                | InvalidId _ | TransitionRejected _ | VerificationSuperseded _)
            | Masc_domain.Agent _ | Masc_domain.Auth _ | Masc_domain.System _) as error) ->
     fail (Masc_domain.masc_error_to_string error)
   | Ok _ -> fail "stale release committed");
  check int "CAS rejection has no backlog effect" actual (read_backlog config).version;
  check_claimed config first operation.keeper_name;
  let stopped = stopped_operation ~config ~stage:Pending_confirm_cleanup operation in
  check_receipt config operation first;
  check_receipt config operation second;
  check_claimed config unrelated "other-owner";
  check int "only the two original Tasks committed" (actual + 2) (read_backlog config).version;
  check int "finalizer records the reobserved committed backlog" (actual + 2)
    stopped.expected_backlog_version)
;;

let test_changed_owner_is_not_released () = with_workspace (fun config ->
  let operation, first, second = operation config in
  ignore (require_task (Workspace.release_task_r config ~agent_name:operation.keeper_name
    ~task_id:first ~handoff_context:(handoff "another-release") ()));
  claim config "other-owner" first;
  let before = (read_backlog config).version in
  ignore (stopped_operation ~config ~stage:Task_settlement operation);
  check_claimed config first "other-owner";
  check_claimed config second operation.keeper_name;
  check int "refused ownership recovery commits nothing" before (read_backlog config).version)
;;

let test_new_active_task_is_not_absorbed () = with_workspace (fun config ->
  let operation, first, second = operation config in
  let newer = add_task config "new work after the frozen shutdown" in
  claim config operation.keeper_name newer;
  let before = (read_backlog config).version in
  ignore (stopped_operation ~config ~stage:Task_settlement operation);
  List.iter (fun id -> check_claimed config id operation.keeper_name) [first; second; newer];
  check int "new work is not absorbed into the old stop" before (read_backlog config).version)
;;

let test_original_release_receipt_is_not_replayed () = with_workspace (fun config ->
  let operation, first, second = operation config in
  ignore (require_task (Workspace.release_task_r config ~agent_name:operation.keeper_name
    ~task_id:first ~handoff_context:(handoff (receipt_ref operation)) ()));
  let preserved = (task config first).handoff_context in
  let before = (read_backlog config).version in
  let stopped = stopped_operation ~config ~stage:Pending_confirm_cleanup operation in
  check_receipt config operation first;
  check_receipt config operation second;
  check bool "prior handoff and receipt were not rewritten" true
    (preserved = (task config first).handoff_context);
  check int "only remaining Task commits" (before + 1) (read_backlog config).version;
  check int "remaining progress is durably recorded" (before + 1) stopped.expected_backlog_version)
;;

let () = run "keeper_shutdown_task_settlement"
  ["Task settlement", [
    test_case "typed CAS is pre-effect and reobservation keeps unrelated ownership" `Quick
      test_typed_cas_and_authoritative_reobservation;
    test_case "a changed owner is never released" `Quick test_changed_owner_is_not_released;
    test_case "new active work is not absorbed" `Quick test_new_active_task_is_not_absorbed;
    test_case "the original release receipt is never replayed" `Quick
      test_original_release_receipt_is_not_replayed]]
