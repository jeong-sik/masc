(* Boot recovery re-enters every durable shutdown operation, including ones
   whose keeper was later removed outright: an operator stop with meta
   removal unregisters the owner and deletes the metadata. An admission
   fence lives inside its Keeper owner, so once the owner is gone and the
   keeper's metadata went with it there is no fence left to release — the
   removal itself achieved the release. Before this settlement existed,
   three durable operations for the deleted keeper [full-cycle-probe]
   failed recovery on every boot (2026-08-12): finalized operations died at
   admission release, the superseded one at the shutdown transition, and no
   code path could retire any of them. A leftover meta without its owner
   stays an error, mirroring the [remove_meta_file] cross-check. *)

open Alcotest
open Masc
open Keeper_shutdown_types

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir path =
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> rm (Filename.concat p name)) (Sys.readdir p);
      Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error _ -> ()
  in
  rm path
;;

let with_workspace f =
  let base = temp_dir "keeper_shutdown_ownerless_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Keeper_shutdown_finalize.register_remove_pending_confirms_by_target
         (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
       Fun.protect
         ~finally:(fun () ->
           Keeper_shutdown_finalize.For_testing
           .reset_remove_pending_confirms_by_target ();
           Keeper_shutdown_finalize.For_testing.reset_completion_handler ();
           Keeper_shutdown_intake_fence.For_testing.reset ();
           Fs_compat.clear_fs ())
         (fun () ->
            let config = Workspace.default_config base in
            let (_init_msg : string) = Workspace.init config ~agent_name:None in
            Eio.Switch.run @@ fun sw ->
            (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
             | Ok 0 -> ()
             | Ok count -> failf "unexpected initial owner count: %d" count
             | Error error ->
               fail (Keeper_owner_registry.install_error_to_string error));
            f ~config))
;;

let fixture_meta_exn name =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String "trace-ownerless-admission-release-test"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error detail -> failf "meta fixture rejected: %s" detail
;;

let trace_id_exn value =
  match Keeper_id.Trace_id.of_string value with
  | Ok trace_id -> trace_id
  | Error detail -> failf "trace id rejected: %s" detail
;;

(* Digest of the meta the original finalization snapshotted. The keeper is
   gone by recovery time, so the digest only has to be well-formed audit
   evidence, not anything present on disk. *)
let removed_keeper_digest name =
  Keeper_meta_json.Snapshot_digest.of_meta (fixture_meta_exn name)
;;

let finalized_after_removal_evidence name =
  { cleanup =
      { settled_task_ids = []
      ; pending_confirms_removed = 0
      ; meta_snapshot_digest = removed_keeper_digest name
      }
  ; meta_removed = true
  ; session_removed = true
  ; registry_unregistered = true
  ; accumulator_dropped = true
  ; completion = Completion_not_requested
  }
;;

(* Evidence for a finalization that kept the Keeper's metadata and session:
   the [Operator_stop_retain_meta] shape. Such a record serves no retirement
   fence, so boot recovery reclaims it. *)
let finalized_retained_evidence name =
  { cleanup =
      { settled_task_ids = []
      ; pending_confirms_removed = 0
      ; meta_snapshot_digest = removed_keeper_digest name
      }
  ; meta_removed = false
  ; session_removed = false
  ; registry_unregistered = true
  ; accumulator_dropped = true
  ; completion = Completion_not_requested
  }
;;

let make_operation ~keeper_name ~phase ~cleanup_intent =
  { schema_version
  ; revision = 1
  ; operation_id = Operation_id.generate ()
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id = trace_id_exn "trace-ownerless-admission-release-test"
  ; actor = "test"
  ; cleanup_intent
  ; turn_disposition = No_inflight_turn
  ; expected_backlog_version = 0
  ; owned_task_ids = []
  ; join_evidence = None
  ; phase
  ; created_at = Masc_domain.now_iso ()
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let persist_exn ~config operation =
  match Keeper_shutdown_store.persist_new ~config operation with
  | Ok () -> ()
  | Error error ->
    failf "persist_new failed: %s" (Keeper_shutdown_store.error_to_string error)
;;

let recover_fence ~config operation =
  Keeper_shutdown_runtime.recover_operation_with_corrupt_owner_fence
    ~config
    ~corrupt_owner_fence:None
    operation
;;

let check_settled label ~config operation =
  match recover_fence ~config operation with
  | Ok recovered ->
    check
      bool
      (label ^ ": settled operation must not fence admission")
      false
      (requires_admission_fence recovered);
    check
      bool
      (label ^ ": settlement keeps the terminal phase")
      true
      (match recovered.phase with
       | Finalized _ | Superseded _ -> true
       | _ -> false)
  | Error detail -> failf "%s: recovery still fails: %s" label detail
;;

let check_intake_fenced label ~config operation =
  check
    bool
    (label ^ ": exact intake fence remains installed")
    true
    (match
       Keeper_shutdown_intake_fence.shutdown_operation_id
         ~base_path:config.Workspace.base_path
         ~keeper_name:operation.keeper_name
     with
     | Some existing -> Operation_id.equal existing operation.operation_id
     | None -> false)
;;

let check_create_meta_rejected label ~config operation =
  match
    Keeper_owner_registry.create_meta
      ~base_path:config.Workspace.base_path
      (fixture_meta_exn operation.keeper_name)
  with
  | Ok _ -> failf "%s: same-name Keeper was recreated through a shutdown fence" label
  | Error _ ->
    check
      int
      (label ^ ": rejected creation did not install an empty Owner")
      0
      (Keeper_owner_registry.For_testing.installed_owner_count
         ~base_path:config.base_path)
;;

let create_owner_meta_exn ~config name =
  match
    Keeper_owner_registry.create_meta
      ~base_path:config.Workspace.base_path
      (fixture_meta_exn name)
  with
  | Ok (Some _) -> ()
  | Ok None -> fail "owner metadata creation removed its snapshot"
  | Error error ->
    fail (Keeper_owner_registry.command_error_to_string error)
;;

let owner_shutdown_operation_id_exn ~config name =
  match
    Keeper_owner_registry.shutdown_operation_id
      ~base_path:config.Workspace.base_path
      ~keeper_name:name
  with
  | Ok operation_id -> operation_id
  | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error)
;;

(* A finalized operation for a keeper whose owner and metadata are both gone
   — the [full-cycle-probe] shape: finalization already removed the meta and
   session, the keeper deletion took the owner, and only the admission
   release was still failing. Recovery must settle it instead of failing
   every boot. *)
let test_finalized_operation_settles_when_keeper_removed () =
  with_workspace (fun ~config ->
    let name = "ownerless-finalized" in
    let operation =
      make_operation
        ~keeper_name:name
        ~phase:(Finalized (finalized_after_removal_evidence name))
        ~cleanup_intent:
          { reason = Operator_stop_remove_meta; remove_session = true }
    in
    persist_exn ~config operation;
    check_settled "finalized" ~config operation;
    (* Durable intake follows current metadata alone, so settlement
       reclaims the operation record instead of keeping it as a fence. *)
    (match
       Keeper_shutdown_store.path
         ~config
         ~keeper_name:name
         operation.operation_id
     with
     | Ok record_path ->
       check
         bool
         "settled removal record is reclaimed"
         false
         (Sys.file_exists record_path)
     | Error error ->
       failf "path: %s" (Keeper_shutdown_store.error_to_string error)))
;;

(* A finalization that retained metadata leaves nothing for any reader: the
   fence is released and there is no retirement to enforce. Boot recovery
   must reclaim the record instead of walking it again at every boot — the
   live fleet accumulated one such record per clean shutdown. *)
let test_settled_retain_meta_record_reclaimed () =
  with_workspace (fun ~config ->
    let name = "retained-finalized" in
    create_owner_meta_exn ~config name;
    let operation =
      make_operation
        ~keeper_name:name
        ~phase:(Finalized (finalized_retained_evidence name))
        ~cleanup_intent:
          { reason = Operator_stop_retain_meta; remove_session = false }
    in
    persist_exn ~config operation;
    check_settled "retain-meta finalized" ~config operation;
    match
      Keeper_shutdown_store.path
        ~config
        ~keeper_name:name
        operation.operation_id
    with
    | Ok record_path ->
      check
        bool
        "settled retain-meta record is reclaimed"
        false
        (Sys.file_exists record_path)
    | Error error ->
      failf "path: %s" (Keeper_shutdown_store.error_to_string error))
;;

(* [delete_terminal] is the only writer allowed to remove records, and it
   must refuse everything that still requires an admission fence. *)
let test_delete_terminal_refuses_fenced_record () =
  with_workspace (fun ~config ->
    let name = "fenced-blocked" in
    let operation =
      make_operation
        ~keeper_name:name
        ~phase:(Blocked { stage = Lane_join; detail = "boot interrupted" })
        ~cleanup_intent:
          { reason = Operator_stop_retain_meta; remove_session = false }
    in
    persist_exn ~config operation;
    (match
       Keeper_shutdown_store.delete_terminal
         ~config
         ~keeper_name:name
         ~operation_id:operation.operation_id
     with
     | Ok Keeper_shutdown_store.Terminal_retained -> ()
     | Ok Keeper_shutdown_store.Terminal_deleted ->
       fail "fence-holding record was deleted"
     | Error error ->
       failf
         "delete_terminal: %s"
         (Keeper_shutdown_store.error_to_string error));
    match
      Keeper_shutdown_store.path
        ~config
        ~keeper_name:name
        operation.operation_id
    with
    | Ok record_path ->
      check
        bool
        "fence-holding record stays on disk"
        true
        (Sys.file_exists record_path)
    | Error error ->
      failf "path: %s" (Keeper_shutdown_store.error_to_string error))
;;

(* A retain-meta supersession cannot use owner absence as removal evidence.
   Its durable contract says metadata remains, so losing both owner and meta
   is an inconsistency that recovery must surface. *)
let test_retain_meta_supersession_does_not_fast_path () =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:"ownerless-superseded"
        ~phase:(Superseded (Operator_metadata_update { actor = "dashboard" }))
        ~cleanup_intent:
          { reason = Operator_stop_retain_meta; remove_session = false }
    in
    persist_exn ~config operation;
    match recover_fence ~config operation with
    | Ok _ -> fail "retain-meta supersession was mistaken for a removed Keeper"
    | Error detail ->
      check
        bool
        "retain-meta inconsistency preserves Owner_not_found"
        true
      (String_util.contains_substring detail "Keeper owner not found"))
;;

let test_ownerless_finalizer_hands_intake_to_corrupt_successor () =
  with_workspace (fun ~config ->
    let name = "ownerless-corrupt-successor" in
    let operation =
      make_operation
        ~keeper_name:name
        ~phase:(Finalized (finalized_after_removal_evidence name))
        ~cleanup_intent:
          { reason = Operator_stop_remove_meta; remove_session = true }
    in
    let successor_operation_id = Operation_id.generate () in
    (match
       Keeper_shutdown_intake_fence.restore_shutdown
         ~base_path:config.base_path
         ~keeper_name:name
         ~operation_id:operation.operation_id
     with
     | Keeper_shutdown_intake_fence.Restored -> ()
     | Keeper_shutdown_intake_fence.Already_restored
     | Keeper_shutdown_intake_fence.Restore_conflict _ ->
       fail "fixture failed to install current intake fence");
    match
      Keeper_shutdown_finalize.run
        ~config
        ~entry:None
        ~successor_operation_id
        operation
    with
    | Error error ->
      failf
        "ownerless corrupt handoff failed: %s"
        (Keeper_shutdown_finalize.error_to_string error)
    | Ok _ ->
      check bool "corrupt successor owns the intake fence" true
        (match
           Keeper_shutdown_intake_fence.shutdown_operation_id
             ~base_path:config.base_path
             ~keeper_name:name
         with
         | Some actual -> Operation_id.equal actual successor_operation_id
         | None -> false);
      check_create_meta_rejected "corrupt successor" ~config operation)
;;

let test_plain_release_keeps_owner_fenced_on_intake_conflict () =
  with_workspace (fun ~config ->
    let name = "release-intake-conflict" in
    let operation =
      make_operation
        ~keeper_name:name
        ~phase:(Finalized (finalized_after_removal_evidence name))
        ~cleanup_intent:
          { reason = Operator_stop_remove_meta; remove_session = true }
    in
    create_owner_meta_exn ~config name;
    (match
       Keeper_owner_registry.begin_shutdown
         ~base_path:config.base_path
         ~keeper_name:name
         ~operation_id:operation.operation_id
     with
     | Ok (Keeper_owner.Shutdown_reserved _)
     | Ok (Keeper_owner.Shutdown_already_reserved _) -> ()
     | Error error ->
       fail (Keeper_owner_registry.command_error_to_string error));
    (match
       Keeper_shutdown_intake_fence.rollback_shutdown
         ~base_path:config.base_path
         ~keeper_name:name
         ~operation_id:operation.operation_id
     with
     | Keeper_shutdown_intake_fence.Rolled_back -> ()
     | Keeper_shutdown_intake_fence.Not_reserved
     | Keeper_shutdown_intake_fence.Reserved_by_other _ ->
       fail "fixture failed to remove the current intake fence");
    let conflicting_operation_id = Operation_id.generate () in
    (match
       Keeper_shutdown_intake_fence.restore_shutdown
         ~base_path:config.base_path
         ~keeper_name:name
         ~operation_id:conflicting_operation_id
     with
     | Keeper_shutdown_intake_fence.Restored -> ()
     | Keeper_shutdown_intake_fence.Already_restored
     | Keeper_shutdown_intake_fence.Restore_conflict _ ->
       fail "fixture failed to install the conflicting intake fence");
    (match Keeper_shutdown_finalize.run ~config ~entry:None operation with
     | Error _ -> ()
     | Ok _ -> fail "conflicting intake fence was reported as released");
    check
      (option string)
      "owner-local admission remains closed after release conflict"
      (Some (Operation_id.to_string operation.operation_id))
      (Option.map
         Operation_id.to_string
         (owner_shutdown_operation_id_exn ~config name)))
;;

(* Metadata that outlived its owner is an inconsistent state, not a removal:
   the release must keep failing so the inconsistency surfaces instead of
   being silently absorbed. *)
let test_meta_without_owner_still_fails () =
  with_workspace (fun ~config ->
    let name = "ownerless-with-meta" in
    let meta = fixture_meta_exn name in
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error detail -> failf "replace_snapshot failed: %s" detail);
    let operation =
      make_operation
        ~keeper_name:name
        ~phase:(Finalized (finalized_after_removal_evidence name))
        ~cleanup_intent:
          { reason = Operator_stop_remove_meta; remove_session = true }
    in
    persist_exn ~config operation;
    match recover_fence ~config operation with
    | Ok _ -> fail "recovery settled an operation whose meta outlived its owner"
    | Error detail ->
      check
        string
        "failure names the admission release"
        "Keeper shutdown admission release failed"
        (String.sub detail 0
           (String.length "Keeper shutdown admission release failed")))
;;

(* Only [Owner_not_found] is a removal signal: a registry that is stopping,
   for example, must not be mistaken for a deleted keeper. *)
let test_predicate_rejects_other_lookup_errors () =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:"ownerless-inventory-stopping"
        ~phase:(Finalized (finalized_after_removal_evidence
                             "ownerless-inventory-stopping"))
        ~cleanup_intent:
          { reason = Operator_stop_remove_meta; remove_session = true }
    in
    check
      bool
      "inventory stopping is not a removal"
      false
      (Keeper_shutdown_finalize.admission_already_released_by_removal
         ~config
         operation
         (Keeper_owner_registry.Command_lookup_failed
            Keeper_owner_registry.Inventory_stopping)))
;;

(* Owner absence plus missing metadata is only terminal removal evidence when
   the operation itself promised [Remove_meta]. Retain-meta operations must
   keep surfacing the inconsistency.

   Every [cleanup_reason] is listed so that adding one forces a decision here
   rather than inheriting whichever answer the new variant happens to fall
   into. [Supervisor_cleanup] is the case that made this matter: it replaced
   [Dead_tombstone_cleanup], whose disposition was retain, and moved to
   [Remove_meta] at the same time. The rename carried the old expectation with
   it and left main red. *)
let test_predicate_answers_every_cleanup_reason () =
  with_workspace (fun ~config ->
    let owner_not_found name =
      Keeper_owner_registry.Command_lookup_failed
        (Keeper_owner_registry.Owner_not_found name)
    in
    let check_reason label reason ~is_removal_evidence =
      let operation =
        make_operation
          ~keeper_name:label
          ~phase:(Blocked { stage = Meta_remove; detail = "fixture" })
          ~cleanup_intent:{ reason; remove_session = false }
      in
      check
        bool
        (label
         ^ ": "
         ^ (if is_removal_evidence then "removal" else "retain")
         ^ " intent decides the admission release")
        is_removal_evidence
        (Keeper_shutdown_finalize.admission_already_released_by_removal
           ~config
           operation
           (owner_not_found label))
    in
    check_reason
      "ownerless-retain-operator"
      Operator_stop_retain_meta
      ~is_removal_evidence:false;
    check_reason
      "ownerless-remove-operator"
      Operator_stop_remove_meta
      ~is_removal_evidence:true;
    check_reason
      "ownerless-supervisor-cleanup"
      Supervisor_cleanup
      ~is_removal_evidence:true;
    check_reason
      "ownerless-dashboard-purge"
      (Dashboard_keeper_purge
         { requested_name = "ownerless-dashboard-purge" })
      ~is_removal_evidence:true)
;;

(* The cases above enter through [recover_operation_with_corrupt_owner_fence].
   Boot does not start there: [recover_at_boot] runs [restore_inventory_admission]
   first, and only operations that still want a fence go through it. Every
   fixture above finalizes with [Completion_not_requested], which
   [requires_admission_fence] answers false for — so none of them ever reached
   the restore pass, and the gate there went unexercised.

   A dashboard purge that crashed between [complete_cleanup] and its completion
   receipt leaves exactly the state that does want a fence: meta and owner gone,
   phase [Finalized { completion = Completion_pending _ }]. Boot must settle it
   rather than abort, or the crash window this suite exists to close stays open
   one gate earlier. *)
let test_boot_recovery_keeps_blocked_ownerless_cleanup_fenced () =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:"ownerless-blocked-cleanup"
        ~phase:
          (Blocked
             { stage = Session_remove
             ; detail = "remove_session_dir failed after remove_meta_file"
             })
        ~cleanup_intent:
          { reason = Operator_stop_remove_meta; remove_session = true }
    in
    persist_exn ~config operation;
    (match Keeper_shutdown_runtime.recover_at_boot ~config with
     | [ Ok recovered ] ->
       check
         bool
         "blocked cleanup remains blocked"
         true
         (match recovered.phase with
          | Blocked _ -> true
          | _ -> false)
     | [ Error detail ] -> failf "blocked cleanup recovery failed: %s" detail
     | outcomes -> failf "unexpected blocked cleanup outcome count: %d" (List.length outcomes));
    check_intake_fenced "blocked cleanup" ~config operation;
    check_create_meta_rejected "blocked cleanup" ~config operation)
;;

let check_boot_recovery_rejects_ownerless_retain_intent label reason =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:label
        ~phase:(Blocked { stage = Meta_remove; detail = "fixture" })
        ~cleanup_intent:{ reason; remove_session = false }
    in
    persist_exn ~config operation;
    (match Keeper_shutdown_runtime.recover_at_boot ~config with
     | [ Error _ ] -> ()
     | [ Ok _ ] -> fail "ownerless retain-meta operation was reported as recovered"
     | outcomes ->
       failf "unexpected retain-meta recovery outcome count: %d" (List.length outcomes));
    check
      bool
      "inconsistent retain-meta state does not install an ownerless fence"
      true
      (Option.is_none
         (Keeper_shutdown_intake_fence.shutdown_operation_id
            ~base_path:config.base_path
            ~keeper_name:operation.keeper_name)))
;;

let test_boot_recovery_rejects_ownerless_operator_retain () =
  check_boot_recovery_rejects_ownerless_retain_intent
    "ownerless-blocked-operator-retain"
    Operator_stop_retain_meta
;;


let check_corrupt_sibling_does_not_hide_ownerless_retain label reason =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:label
        ~phase:(Blocked { stage = Meta_remove; detail = "fixture" })
        ~cleanup_intent:{ reason; remove_session = false }
    in
    let corrupt_sibling =
      { operation with operation_id = Operation_id.generate () }
    in
    persist_exn ~config operation;
    persist_exn ~config corrupt_sibling;
    let corrupt_path =
      match
        Keeper_shutdown_store.path
          ~config
          ~keeper_name:label
          corrupt_sibling.operation_id
      with
      | Ok path -> path
      | Error error ->
        fail (Keeper_shutdown_store.error_to_string error)
    in
    (match Fs_compat.save_file_atomic corrupt_path "{not-json" with
     | Ok () -> ()
     | Error detail -> fail detail);
    (match Keeper_shutdown_runtime.recover_at_boot ~config with
     | [ Error _ ] -> ()
     | [ Ok _ ] ->
       fail "corrupt sibling hid the ownerless retain-meta inconsistency"
     | outcomes ->
       failf
         "unexpected corrupt-sibling recovery outcome count: %d"
         (List.length outcomes));
    check
      bool
      "invalid current operation did not acquire a corrupt-only fence"
      true
      (Option.is_none
         (Keeper_shutdown_intake_fence.shutdown_operation_id
            ~base_path:config.base_path
            ~keeper_name:label)))
;;

let test_corrupt_sibling_does_not_hide_ownerless_operator_retain () =
  check_corrupt_sibling_does_not_hide_ownerless_retain
    "ownerless-corrupt-operator-retain"
    Operator_stop_retain_meta
;;


let pending_completion_operation name =
  let evidence = finalized_after_removal_evidence name in
  make_operation
    ~keeper_name:name
    ~phase:
      (Finalized
         { evidence with completion = Completion_pending Dashboard_keeper_purged })
    ~cleanup_intent:
      { reason = Dashboard_keeper_purge { requested_name = name }
      ; remove_session = true
      }
;;

let test_boot_recovery_keeps_failed_pending_completion_fenced () =
  with_workspace (fun ~config ->
    let operation = pending_completion_operation "ownerless-pending-failed" in
    Keeper_shutdown_finalize.register_completion_handler
      (fun _config _operation _action -> Error "completion unavailable");
    persist_exn ~config operation;
    (match Keeper_shutdown_runtime.recover_at_boot ~config with
     | [ Error detail ] ->
       check
         bool
         "pending completion failure is reported"
         true
         (String_util.contains_substring detail "completion unavailable")
     | [ Ok _ ] -> fail "failed pending completion was reported as recovered"
     | outcomes ->
       failf "unexpected pending completion outcome count: %d" (List.length outcomes));
    check_intake_fenced "failed pending completion" ~config operation;
    check_create_meta_rejected "failed pending completion" ~config operation)
;;

let test_boot_recovery_settles_pending_completion_after_removal () =
  with_workspace (fun ~config ->
    let name = "ownerless-pending-completion" in
    (* [Completion_pending Dashboard_keeper_purged] is only a valid record next
       to a [Dashboard_keeper_purge] intent — the store rejects any other
       pairing (Finalized_completion_mismatch). That pairing is also exactly
       the reported scenario: a dashboard purge that crashed before its
       receipt. *)
    let operation = pending_completion_operation name in
    check
      bool
      "fixture must be one the restore pass actually fences"
      true
      (requires_admission_fence operation);
    (* Settling the fence is only half of this boot: the pending receipt is then
       delivered, and without a registered handler that step fails for a reason
       unrelated to the gate under test. Record the delivery so the assertion
       below is about recovery reaching the end, not about harness wiring. *)
    let delivered = ref [] in
    Keeper_shutdown_finalize.register_completion_handler
      (fun _config delivered_operation action ->
         delivered := (delivered_operation.keeper_name, action) :: !delivered;
         Ok ());
    persist_exn ~config operation;
    match Keeper_shutdown_runtime.recover_at_boot ~config with
    | [] -> failf "boot recovery returned no outcome for %s" name
    | outcomes ->
      List.iter
        (function
          | Ok _ -> ()
          | Error detail -> failf "boot recovery still fails: %s" detail)
        outcomes;
      (* The receipt the crash lost is what recovery owes: settling the fence
         without delivering it would leave the purge half-finished. *)
      check
        (list (pair string string))
        "boot delivers the pending completion it recovered"
        [ name, "dashboard_keeper_purged" ]
        (List.rev_map
           (fun (keeper, action) -> keeper, completion_action_to_string action)
           !delivered);
      check
        bool
        "delivered receipt releases the exact intake fence"
        true
        (Option.is_none
           (Keeper_shutdown_intake_fence.shutdown_operation_id
              ~base_path:config.base_path
              ~keeper_name:name)))
;;

module Reconciliation = Keeper_shutdown_reconciliation

let retained_absent_operation name =
  let operation = make_operation ~keeper_name:name
      ~phase:(Finalized (finalized_retained_evidence name))
      ~cleanup_intent:{ reason = Operator_stop_retain_meta; remove_session = false } in
  { operation with join_evidence = Some
      { lane_outcome = Lane_shutdown_requested; terminal = Terminal_stopped; cleanup_error = None } }
;;

let strict_backlog_exn config =
  match Workspace_backlog.read_backlog_r config with
  | Ok backlog -> backlog | Error detail -> fail detail
;;

let acknowledge ?revision ?backlog_version ~config operation =
  Reconciliation.acknowledge_absent_owner ~config ~keeper_name:operation.keeper_name
    ~operation_id:operation.operation_id
    ~expected_revision:(Option.value revision ~default:operation.revision)
    ~expected_backlog_version:(Option.value backlog_version
      ~default:(strict_backlog_exn config).version)
    ~actor:"operator" ~reason:"Confirmed owner and canonical files are absent"
;;

let acknowledged_exn = function
  | Ok (Keeper_shutdown_store.Absence_acknowledged operation
       | Keeper_shutdown_store.Absence_already_acknowledged operation) -> operation
  | Error error -> fail (Reconciliation.error_to_string error)
;;

let load_operation_exn ~config operation =
  match Keeper_shutdown_store.load ~config ~keeper_name:operation.keeper_name operation.operation_id with
  | Ok current -> current | Error error -> fail (Keeper_shutdown_store.error_to_string error)
;;

let chat_store_ok = function
  | Ok value -> value
  | Error error -> fail (Keeper_chat_operation_store.error_to_string error)
;;

let test_absence_acknowledgement_checks_durable_chat_operations () =
  with_workspace (fun ~config ->
    let module Store = Keeper_chat_operation_store in
    let operation = retained_absent_operation "absent-ack-chat" in
    persist_exn ~config operation;
    let path = Store.path_for_keeper
      ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_name:operation.keeper_name in
    Unix.mkdir (Filename.dirname path) 0o755;
    let operation_id = match Keeper_chat_operation.Operation_id.of_string "unsettled-chat" with
      | Ok id -> id | Error detail -> fail detail in
    let store = chat_store_ok (Store.open_or_create ~path) in
    Fun.protect ~finally:(fun () -> ignore (Store.close store)) (fun () ->
      ignore (chat_store_ok (Store.submit store ~now:1. ~operation_id
        ~source:(`Assoc ["kind", `String "dashboard"])
        ~input:(`Assoc ["message", `String "durable queued work"])));
      let require_refusal label =
        (match acknowledge ~config operation with
         | Error (Reconciliation.Outstanding_chat_operations [observed]) ->
           check bool label true (Keeper_chat_operation.Operation_id.equal operation_id observed)
         | Error error -> fail (Reconciliation.error_to_string error)
         | Ok _ -> fail "outstanding chat operation authorized acknowledgement");
        check bool "refusal preserves shutdown evidence" true
          (load_operation_exn ~config operation = operation)
      in
      require_refusal "queued operation identity";
      ignore (chat_store_ok (Store.claim_next store ~now:2.));
      require_refusal "running operation identity";
      ignore (chat_store_ok (Store.succeed_running store ~now:3. ~operation_id
        ~outcome_ref:"receipt:confirmed-terminal")));
    let before = In_channel.with_open_bin path In_channel.input_all in
    ignore (acknowledged_exn (acknowledge ~config operation));
    check string "read-only check preserves operation bytes" before
      (In_channel.with_open_bin path In_channel.input_all))
;;

let test_absence_acknowledgement_rejects_corrupt_chat_store () =
  with_workspace (fun ~config ->
    let module Store = Keeper_chat_operation_store in
    let operation = retained_absent_operation "absent-ack-corrupt-chat" in
    persist_exn ~config operation;
    let path = Store.path_for_keeper
      ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_name:operation.keeper_name in
    Unix.mkdir (Filename.dirname path) 0o755;
    Out_channel.with_open_bin path (fun channel -> output_string channel "corrupt operation evidence");
    (match acknowledge ~config operation with
     | Error (Reconciliation.Chat_operations_unavailable _) -> ()
     | _ -> fail "corrupt chat database treated as an empty queue");
    check string "corrupt database not initialized or repaired" "corrupt operation evidence"
      (In_channel.with_open_bin path In_channel.input_all);
    check bool "failed inspection preserves original evidence" true
      (load_operation_exn ~config operation = operation))
;;

let test_absence_acknowledgement_retains_evidence_and_recovery () =
  with_workspace (fun ~config ->
    let operation = retained_absent_operation "absent-ack" in
    persist_exn ~config operation;
    (match recover_fence ~config operation with
     | Error _ -> () | Ok _ -> fail "unacknowledged retained owner must still fail");
    ignore (Keeper_shutdown_intake_fence.restore_shutdown ~base_path:config.base_path
      ~keeper_name:operation.keeper_name ~operation_id:operation.operation_id);
    let acknowledged = acknowledged_exn (acknowledge ~config operation) in
    check bool "matching reservation released after commit" true
      (Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path:config.base_path
        ~keeper_name:operation.keeper_name = None);
    ignore (Keeper_shutdown_intake_fence.restore_shutdown ~base_path:config.base_path
      ~keeper_name:operation.keeper_name ~operation_id:operation.operation_id);
    let crash_replay = acknowledged_exn (acknowledge ~config operation) in
    check bool "post-CAS pre-release crash replay preserves evidence" true (crash_replay = acknowledged);
    check bool "crash replay releases only the old reservation" true
      (Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path:config.base_path
        ~keeper_name:operation.keeper_name = None);
    (match acknowledged.phase, operation.phase with
     | Operator_absence_acknowledged ack, Finalized original ->
       check bool "original finalization retained" true (ack.finalization = original);
       check bool "no fabricated removal" false ack.finalization.meta_removed;
       check string "authenticated caller attribution" "operator" ack.actor;
       check int "exact prior revision" operation.revision ack.prior_revision
     | _ -> fail "expected retained acknowledgement");
    check int "one CAS increment" (operation.revision + 1) acknowledged.revision;
    let reread = load_operation_exn ~config operation in
    check bool "durable codec round trip" true (reread = acknowledged);
    (match Keeper_shutdown_runtime.recover_at_boot ~config with
     | [Ok recovered] -> check bool "boot keeps acknowledged record" true (recovered = acknowledged)
     | _ -> fail "acknowledged owner returned to finalization");
    (match Keeper_shutdown_store.delete_terminal ~config ~keeper_name:operation.keeper_name
             ~operation_id:operation.operation_id with
     | Ok Keeper_shutdown_store.Terminal_retained -> ()
     | _ -> fail "audit acknowledgement was erased");
    let repeated = acknowledged_exn (acknowledge ~config operation) in
    check bool "retry does not change revision or evidence" true (repeated = acknowledged);
    (match acknowledged.phase with
     | Operator_absence_acknowledged ack ->
       let tampered = { acknowledged with phase = Operator_absence_acknowledged
           { ack with prior_operation_sha256 = String.make 64 '0' } } in
       (match Keeper_shutdown_store.of_json (Keeper_shutdown_store.to_json tampered) with
        | Error _ -> () | Ok _ -> fail "tampered original observation accepted")
     | _ -> fail "missing acknowledgement"))
;;

let test_absence_acknowledgement_refuses_present_paths_and_conflicts () =
  with_workspace (fun ~config ->
    let operation = retained_absent_operation "absent-ack-conflict" in
    persist_exn ~config operation;
    let unchanged () = check bool "refusal leaves original evidence" true
        (load_operation_exn ~config operation = operation) in
    (match acknowledge ~revision:(operation.revision + 1) ~config operation with
     | Error (Reconciliation.Store_error (Keeper_shutdown_store.Revision_conflict _)) -> ()
     | _ -> fail "stale revision accepted");
    unchanged ();
    (match acknowledge ~backlog_version:((strict_backlog_exn config).version + 1) ~config operation with
     | Error (Reconciliation.Backlog_revision_conflict _) -> ()
     | _ -> fail "stale backlog version accepted");
    unchanged ();
    let meta_path = Keeper_types_profile.keeper_meta_path config operation.keeper_name in
    let oc = open_out meta_path in output_string oc "{broken"; close_out oc;
    (match acknowledge ~config operation with
     | Error (Reconciliation.Path_present path) -> check string "canonical corrupt file" meta_path path
     | _ -> fail "corrupt metadata treated as absence");
    unchanged ();
    Sys.remove meta_path;
    Unix.symlink (meta_path ^ ".missing") meta_path;
    (match acknowledge ~config operation with
     | Error (Reconciliation.Path_present _) -> ()
     | _ -> fail "dangling metadata symlink treated as absence");
    Sys.remove meta_path;
    unchanged ();
    create_owner_meta_exn ~config operation.keeper_name;
    (match acknowledge ~config operation with
     | Error Reconciliation.Owner_present -> ()
     | _ -> fail "new owner was acknowledged absent");
    unchanged ())
;;

let test_absence_acknowledgement_preserves_corrupt_sibling_fence () =
  with_workspace (fun ~config ->
    let operation = retained_absent_operation "absent-ack-corrupt" in
    persist_exn ~config operation;
    let sibling = { operation with operation_id = Operation_id.generate () } in
    persist_exn ~config sibling;
    let sibling_path = match Keeper_shutdown_store.path ~config
        ~keeper_name:sibling.keeper_name sibling.operation_id with
      | Ok path -> path | Error error -> fail (Keeper_shutdown_store.error_to_string error) in
    let oc = open_out sibling_path in output_string oc "{broken"; close_out oc;
    ignore (Keeper_shutdown_intake_fence.restore_shutdown ~base_path:config.base_path
      ~keeper_name:sibling.keeper_name ~operation_id:sibling.operation_id);
    (match acknowledge ~config operation with
     | Error (Reconciliation.Corrupt_sibling _) -> ()
     | _ -> fail "corrupt sibling did not refuse acknowledgement");
    check bool "original retained" true (load_operation_exn ~config operation = operation);
    check bool "corrupt sibling fence retained" true
      (match Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path:config.base_path
          ~keeper_name:operation.keeper_name with
       | Some id -> Operation_id.equal id sibling.operation_id | None -> false))
;;

let test_lifecycle_key_is_retained_across_gc () =
  with_workspace (fun ~config ->
    Eio.Switch.run @@ fun sw ->
    let keeper_name = "lifecycle-key-gc" in
    let locked, locked_r = Eio.Promise.create () in
    let release, release_r = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Keeper_lifecycle_reservation.with_key_lock ~base_path:config.base_path ~keeper_name
        (fun () -> Eio.Promise.resolve locked_r (); Eio.Promise.await release));
    Eio.Promise.await locked;
    Gc.full_major ();
    let second_entered = ref false in
    let done_p, done_r = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Keeper_lifecycle_reservation.with_key_lock ~base_path:config.base_path ~keeper_name
        (fun () -> second_entered := true);
      Eio.Promise.resolve done_r ());
    Eio.Fiber.yield ();
    check bool "GC cannot create a second lock for the held key" false !second_entered;
    Eio.Promise.resolve release_r ();
    Eio.Promise.await done_p;
    check bool "same-key waiter progresses after release" true !second_entered)
;;

let test_absence_acknowledgement_orders_real_creation () =
  with_workspace (fun ~config ->
    let operation = retained_absent_operation "absent-ack-creation" in
    persist_exn ~config operation;
    Eio.Switch.run @@ fun sw ->
    let locked, locked_r = Eio.Promise.create () in
    let release, release_r = Eio.Promise.create () in
    let expected_backlog_version = (strict_backlog_exn config).version in
    let ack_result, ack_result_r = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let result = Reconciliation.For_testing.acknowledge_absent_owner
        ~on_guards_acquired:(fun () -> Eio.Promise.resolve locked_r (); Eio.Promise.await release)
        ~config ~keeper_name:operation.keeper_name ~operation_id:operation.operation_id
        ~expected_revision:operation.revision ~expected_backlog_version
        ~actor:"operator" ~reason:"Confirmed owner and canonical files are absent" in
      Eio.Promise.resolve ack_result_r result);
    Eio.Promise.await locked;
    let creator_done, creator_done_r = Eio.Promise.create () in
    let registry_done, registry_done_r = Eio.Promise.create () in
    let created = ref false and registered = ref false in
    Eio.Fiber.fork ~sw (fun () ->
      create_owner_meta_exn ~config operation.keeper_name;
      created := true;
      Eio.Promise.resolve creator_done_r ());
    Eio.Fiber.fork ~sw (fun () ->
      ignore (Keeper_registry.register_offline ~base_path:config.base_path
        operation.keeper_name (fixture_meta_exn operation.keeper_name));
      registered := true;
      Eio.Promise.resolve registry_done_r ());
    Eio.Fiber.yield ();
    check bool "meta creator waits for reconciliation" false !created;
    check bool "ordinary registry writer waits for reconciliation" false !registered;
    Eio.Promise.resolve release_r ();
    let acknowledged = acknowledged_exn (Eio.Promise.await ack_result) in
    Eio.Promise.await creator_done;
    Eio.Promise.await registry_done;
    let successor = Operation_id.generate () in
    ignore (Keeper_shutdown_intake_fence.restore_shutdown ~base_path:config.base_path
      ~keeper_name:operation.keeper_name ~operation_id:successor);
    let repeated = acknowledged_exn (acknowledge ~config operation) in
    check bool "retry does not inspect or overwrite the new owner" true (repeated = acknowledged);
    check bool "retry preserves new owner's reservation" true
      (match Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path:config.base_path
          ~keeper_name:operation.keeper_name with
       | Some id -> Operation_id.equal id successor | None -> false))
;;

let test_absence_acknowledgement_refuses_task_and_receipt_obligations () =
  with_workspace (fun ~config ->
    let operation = retained_absent_operation "absent-ack-tasks" in
    persist_exn ~config operation;
    let added = match Workspace.add_task_with_result config ~title:"owned work"
        ~priority:1 ~description:"retained owner obligation" with
      | Ok added -> added | Error error -> fail (Workspace.add_task_error_to_string error) in
    let now = Masc_domain.now_iso () in
    let statuses =
      [ Masc_domain.Claimed { assignee = operation.keeper_name; claimed_at = now }
      ; Masc_domain.AwaitingVerification
          { assignee = operation.keeper_name; started_at = now; submitted_at = now
          ; intent = Masc_domain.Complete_task; verification_id = "verification-absence-fixture" } ] in
    List.iter (fun status ->
      let backlog = strict_backlog_exn config in
      Workspace_backlog.write_backlog config
        { backlog with tasks = List.map (fun (task : Masc_domain.task) ->
            if task.id = added.task_id then { task with task_status = status } else task) backlog.tasks };
      (match acknowledge ~config operation with
       | Error (Reconciliation.Outstanding_tasks ids) ->
         check (list string) "exact unresolved task identity" [added.task_id] ids
       | _ -> fail "outstanding task/verification obligation was acknowledged");
      check bool "task refusal preserves original operation" true
        (load_operation_exn ~config operation = operation)) statuses;
    let pending = pending_completion_operation "absent-ack-receipt" in
    persist_exn ~config pending;
    (match acknowledge ~config pending with
     | Error Reconciliation.Ineligible_operation -> ()
     | _ -> fail "pending completion receipt was acknowledged"))
;;

let test_absence_acknowledgement_requires_authoritative_backlog_and_no_declaration () =
  with_workspace (fun ~config ->
    let operation = retained_absent_operation "absent-ack-config" in
    persist_exn ~config operation;
    let old_config = Sys.getenv_opt "MASC_CONFIG_DIR" in
    let root = Filename.concat config.base_path "ack-config" in
    let keepers = Filename.concat root "keepers" in
    Unix.mkdir root 0o700;
    Unix.mkdir keepers 0o700;
    Fun.protect ~finally:(fun () -> Unix.putenv "MASC_CONFIG_DIR"
      (Option.value old_config ~default:"")) (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" root;
      let declaration = Filename.concat keepers (operation.keeper_name ^ ".toml") in
      let oc = open_out declaration in output_string oc "malformed declaration"; close_out oc;
      (match acknowledge ~config operation with
       | Error (Reconciliation.Path_present path) -> check string "resolved declaration path" declaration path
       | _ -> fail "present/corrupt declaration was treated as absence");
      Sys.remove declaration;
      let backlog = strict_backlog_exn config in
      (* A valid recovery copy cannot authorize a decision over a corrupt primary. *)
      Workspace_backlog.write_backlog config backlog;
      let expected = (strict_backlog_exn config).version in
      let oc = open_out (Workspace_backlog.backlog_path config) in
      output_string oc "{corrupt"; close_out oc;
      (match Reconciliation.acknowledge_absent_owner ~config
          ~keeper_name:operation.keeper_name ~operation_id:operation.operation_id
          ~expected_revision:operation.revision ~expected_backlog_version:expected
          ~actor:"operator" ~reason:"test authoritative rejection" with
       | Error (Reconciliation.Backlog_unavailable _) -> ()
       | _ -> fail "recovered backlog authorized absence acknowledgement");
      check bool "refusals leave original operation" true
        (load_operation_exn ~config operation = operation)))
;;

let () =
  Alcotest.run
    "keeper_shutdown_ownerless_admission_release"
    [ ( "recovery"
      , [ Alcotest.test_case "absence acknowledgement checks durable queued and running chat" `Quick
            test_absence_acknowledgement_checks_durable_chat_operations
        ; Alcotest.test_case "absence acknowledgement refuses corrupt chat evidence" `Quick
            test_absence_acknowledgement_rejects_corrupt_chat_store
        ; Alcotest.test_case "absence acknowledgement rejects tasks and completion receipts" `Quick
            test_absence_acknowledgement_refuses_task_and_receipt_obligations
        ; Alcotest.test_case "absence acknowledgement checks declaration and authoritative backlog" `Quick
            test_absence_acknowledgement_requires_authoritative_backlog_and_no_declaration
        ; Alcotest.test_case "absence acknowledgement retains evidence and survives recovery" `Quick
            test_absence_acknowledgement_retains_evidence_and_recovery
        ; Alcotest.test_case "absence acknowledgement rejects paths and CAS conflicts" `Quick
            test_absence_acknowledgement_refuses_present_paths_and_conflicts
        ; Alcotest.test_case "absence acknowledgement preserves corrupt sibling fence" `Quick
            test_absence_acknowledgement_preserves_corrupt_sibling_fence
        ; Alcotest.test_case "lifecycle key remains reachable across suspended callback and GC" `Quick
            test_lifecycle_key_is_retained_across_gc
        ; Alcotest.test_case "absence acknowledgement orders real metadata and registry creation" `Quick
            test_absence_acknowledgement_orders_real_creation
        ; Alcotest.test_case
            "finalized operation settles when keeper removed"
            `Quick
            test_finalized_operation_settles_when_keeper_removed
        ; Alcotest.test_case
            "settled retain-meta record is reclaimed"
            `Quick
            test_settled_retain_meta_record_reclaimed
        ; Alcotest.test_case
            "delete_terminal refuses a fence-holding record"
            `Quick
            test_delete_terminal_refuses_fenced_record
        ; Alcotest.test_case
            "blocked ownerless cleanup keeps admission fenced"
            `Quick
            test_boot_recovery_keeps_blocked_ownerless_cleanup_fenced
        ; Alcotest.test_case
            "ownerless operator-retain inconsistency fails boot recovery"
            `Quick
            test_boot_recovery_rejects_ownerless_operator_retain
        ; Alcotest.test_case
            "failed pending completion keeps admission fenced"
            `Quick
            test_boot_recovery_keeps_failed_pending_completion_fenced
        ; Alcotest.test_case
            "boot recovery settles a pending completion after removal"
            `Quick
            test_boot_recovery_settles_pending_completion_after_removal
        ; Alcotest.test_case
            "retain-meta supersession does not fast-path removal"
            `Quick
            test_retain_meta_supersession_does_not_fast_path
        ; Alcotest.test_case
            "ownerless finalizer hands intake to corrupt successor"
            `Quick
            test_ownerless_finalizer_hands_intake_to_corrupt_successor
        ; Alcotest.test_case
            "plain release keeps owner fenced on intake conflict"
            `Quick
            test_plain_release_keeps_owner_fenced_on_intake_conflict
        ; Alcotest.test_case
            "meta without owner still fails"
            `Quick
            test_meta_without_owner_still_fails
        ; Alcotest.test_case
            "predicate rejects other lookup errors"
            `Quick
            test_predicate_rejects_other_lookup_errors
        ; Alcotest.test_case
            "predicate answers every cleanup reason"
            `Quick
            test_predicate_answers_every_cleanup_reason
        ; Alcotest.test_case
            "corrupt sibling does not hide ownerless operator-retain"
            `Quick
            test_corrupt_sibling_does_not_hide_ownerless_operator_retain
        ] )
    ]
;;
