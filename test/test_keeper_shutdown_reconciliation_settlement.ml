(* Boot recovery must settle an admission-time in-flight turn instead of
   parking the operation in [Reconciliation_required] — a phase with no exit
   transition (#25491). Five keepers stayed unbootable across restarts on
   2026-07-20/21 because durable operations in that phase re-reserved the
   admission fence every boot while worker, recovery, finalize and
   supersession all refused to touch them. *)

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
  let base = temp_dir "keeper_shutdown_reconciliation_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       (* Production registers this at bootstrap; the settled operations here
          own no pending confirms, so a counting no-op keeps finalization on
          its real path. *)
       Keeper_shutdown_finalize.register_remove_pending_confirms_by_target
         (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
       Fun.protect
         ~finally:(fun () ->
           Keeper_shutdown_finalize.For_testing
           .reset_remove_pending_confirms_by_target ();
           Fs_compat.clear_fs ())
         (fun () ->
            let config = Workspace.default_config base in
            let (_init_msg : string) = Workspace.init config ~agent_name:None in
            f ~config))
;;

let trace_id_exn value =
  match Keeper_id.Trace_id.of_string value with
  | Ok trace_id -> trace_id
  | Error detail -> failf "trace id rejected: %s" detail
;;

(* Finalization reads the keeper's meta file (Meta_update stage), so the
   settled operation only completes for a keeper that exists — as every
   live wedged keeper did. *)
let write_keeper_meta_exn ~config ~keeper_name =
  let json =
    `Assoc
      [ "name", `String keeper_name
      ; "agent_name", `String (Printf.sprintf "keeper-%s-agent" keeper_name)
      ; "trace_id", `String "trace-reconciliation-settlement-test"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    (match Keeper_meta_store.write_meta config meta with
     | Ok () -> ()
     | Error detail -> failf "write_meta failed: %s" detail)
  | Error detail -> failf "meta fixture rejected: %s" detail
;;

let inflight_turn =
  { lane = Some Autonomous
  ; admitted_at = Some 1784545390.2
  ; observed_turn_id = Some 5744
  ; observation_started_at = Some 1784545390.2
  }
;;

let make_operation ~keeper_name ~phase ~turn_disposition =
  { schema_version = Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id = Operation_id.generate ()
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id = trace_id_exn "trace-reconciliation-settlement-test"
  ; generation = 0
  ; actor = "test"
  ; cleanup_intent = { reason = Operator_stop_retain_meta; remove_session = false }
  ; turn_disposition
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

let recover_exn ~config operation =
  match Keeper_shutdown_runtime.recover_operation ~config operation with
  | Ok recovered -> recovered
  | Error detail ->
    let blocked_detail =
      match
        Keeper_shutdown_store.load
          ~config
          ~keeper_name:operation.keeper_name
          operation.operation_id
      with
      | Ok { phase = Blocked { detail = blocked; _ }; _ } -> blocked
      | Ok _ | Error _ -> "(no blocked detail on durable record)"
    in
    failf "recover_operation failed: %s — blocked: %s" detail blocked_detail
;;

let phase_label operation =
  match operation.phase with
  | Prepared -> "prepared"
  | Joined_idle -> "joined_idle"
  | Finalizing_tasks _ -> "finalizing_tasks"
  | Cleanup_ready _ -> "cleanup_ready"
  | Reconciliation_required _ -> "reconciliation_required"
  | Finalized _ -> "finalized"
  | Blocked _ -> "blocked"
  | Superseded _ -> "superseded"
;;

(* A durable operation already parked in [Reconciliation_required] (written
   by an older binary) must leave that phase at boot recovery and release the
   admission fence: the owning process ended, so the observed turn cannot
   still be executing. *)
let test_recovery_settles_parked_reconciliation_required () =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:"reconciliation-parked"
        ~phase:(Reconciliation_required inflight_turn)
        ~turn_disposition:(Inflight_effect_unknown inflight_turn)
    in
    write_keeper_meta_exn ~config ~keeper_name:operation.keeper_name;
    persist_exn ~config operation;
    let recovered = recover_exn ~config operation in
    (match recovered.phase with
     | Reconciliation_required _ ->
       fail "recovery left the operation parked in reconciliation_required"
     | _ -> ());
    check
      bool
      (Printf.sprintf
         "settled operation must not fence admission (phase=%s)"
         (phase_label recovered))
      false
      (requires_admission_fence recovered);
    check
      bool
      "admission-time snapshot stays on the operation as an audit record"
      true
      (match recovered.turn_disposition with
       | Inflight_effect_unknown _ -> true
       | No_inflight_turn -> false))
;;

(* A [Prepared] operation whose process died mid-turn settles the same way:
   the process boundary is the reconciliation evidence, and the join evidence
   records the crash. *)
let test_recovery_settles_prepared_with_inflight_turn () =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:"reconciliation-prepared"
        ~phase:Prepared
        ~turn_disposition:(Inflight_effect_unknown inflight_turn)
    in
    write_keeper_meta_exn ~config ~keeper_name:operation.keeper_name;
    persist_exn ~config operation;
    let recovered = recover_exn ~config operation in
    (match recovered.phase with
     | Reconciliation_required _ ->
       fail "boot recovery re-created the exitless reconciliation_required phase"
     | _ -> ());
    check
      bool
      (Printf.sprintf
         "recovered operation must not fence admission (phase=%s)"
         (phase_label recovered))
      false
      (requires_admission_fence recovered);
    check
      bool
      "join evidence records the process death"
      true
      (match recovered.join_evidence with
       | Some { terminal = Terminal_crashed _; _ } -> true
       | Some { terminal = Terminal_stopped; _ } | None -> false))
;;

(* No-regression: the pre-existing recovery of a [Prepared] operation with no
   in-flight turn keeps settling. *)
let test_recovery_still_settles_prepared_without_turn () =
  with_workspace (fun ~config ->
    let operation =
      make_operation
        ~keeper_name:"reconciliation-idle"
        ~phase:Prepared
        ~turn_disposition:No_inflight_turn
    in
    write_keeper_meta_exn ~config ~keeper_name:operation.keeper_name;
    persist_exn ~config operation;
    let recovered = recover_exn ~config operation in
    check
      bool
      (Printf.sprintf
         "recovered idle operation must not fence admission (phase=%s)"
         (phase_label recovered))
      false
      (requires_admission_fence recovered))
;;

let () =
  run
    "keeper-shutdown-reconciliation-settlement"
    [ ( "boot recovery"
      , [ test_case
            "settles a parked reconciliation_required operation"
            `Quick
            test_recovery_settles_parked_reconciliation_required
        ; test_case
            "settles a prepared operation with an in-flight turn"
            `Quick
            test_recovery_settles_prepared_with_inflight_turn
        ; test_case
            "still settles a prepared operation without a turn"
            `Quick
            test_recovery_still_settles_prepared_without_turn
        ] )
    ]
;;
