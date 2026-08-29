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

let () =
  Alcotest.run
    "keeper_shutdown_ownerless_admission_release"
    [ ( "recovery"
      , [ Alcotest.test_case
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
