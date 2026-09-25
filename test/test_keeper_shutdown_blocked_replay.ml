(* #38859: a [Blocked] shutdown at a stage that does not hold the admission
   fence used to be left alone at boot. The fence was released, nothing
   replayed or closed the record, and an operator stop whose metadata latch
   write failed ([Meta_update]) was silently lost: the Keeper autobooted and
   the record stayed on disk for every later boot.

   Boot recovery now replays such a record to completion, or closes it with a
   warning when the Keeper or a later operation overtook it. These cases go
   through [recover_at_boot], the same entry the server uses, so the boot
   fence restore and the recovery run together. *)

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
  let base = temp_dir "keeper_shutdown_blocked_replay_" in
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
           Fs_compat.clear_fs ())
         (fun () ->
            let config = Workspace.default_config base in
            let (_init_msg : string) = Workspace.init config ~agent_name:None in
            Eio.Switch.run @@ fun sw ->
            (match
               Keeper_owner_registry.install_from_store
                 ~sw
                 ~operation_runner:None
                 ~on_turn_slot_released:None
                 config
             with
             | Ok 0 -> ()
             | Ok count -> failf "unexpected initial owner count: %d" count
             | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
            f ~config))
;;

let trace_id_exn value =
  match Keeper_id.Trace_id.of_string value with
  | Ok trace_id -> trace_id
  | Error detail -> failf "trace id rejected: %s" detail
;;

let operation_trace = "trace-blocked-replay-test"

let write_keeper_meta_exn ~(config : Workspace.config) ~keeper_name ~trace =
  let json = `Assoc [ "name", `String keeper_name; "trace_id", `String trace ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    (match Keeper_owner_registry.create_meta ~base_path:config.base_path meta with
     | Ok (Some _) -> ()
     | Ok None -> fail "owner create removed metadata"
     | Error error ->
       failf "owner create failed: %s" (Keeper_owner_registry.command_error_to_string error))
  | Error detail -> failf "meta fixture rejected: %s" detail
;;

let make_operation ~keeper_name ~phase ~created_at =
  { schema_version = Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id = Operation_id.generate ()
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id = trace_id_exn operation_trace
  ; actor = "operator"
  ; cleanup_intent = { reason = Operator_stop_retain_meta; remove_session = false }
  ; turn_disposition = No_inflight_turn
  ; expected_backlog_version = 0
  ; owned_task_ids = []
  ; join_evidence = None
  ; phase
  ; created_at
  ; updated_at = created_at
  }
;;

(* The issue's timeline: lanes joined and tasks settled, then the retained
   latch write failed. *)
let latch_write_failed =
  Blocked { stage = Meta_update; detail = "fixture: Retain_shutdown_latch write failed" }
;;

let persist_exn ~config operation =
  match Keeper_shutdown_store.persist_new ~config operation with
  | Ok () -> ()
  | Error error -> failf "persist_new failed: %s" (Keeper_shutdown_store.error_to_string error)
;;

let recovered_exn results (operation : Keeper_shutdown_types.t) =
  let matching =
    List.filter_map
      (function
        | Ok (recovered : Keeper_shutdown_types.t)
          when Operation_id.equal recovered.operation_id operation.operation_id ->
          Some recovered
        | Ok _ -> None
        | Error detail -> failf "boot recovery failed: %s" detail)
      results
  in
  match matching with
  | [ recovered ] -> recovered
  | outcomes -> failf "expected one outcome for the operation, got %d" (List.length outcomes)
;;

let keeper_meta_exn ~(config : Workspace.config) ~keeper_name =
  match Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name with
  | Error error -> failf "owner lookup failed: %s" (Keeper_owner_registry.lookup_error_to_string error)
  | Ok owner ->
    (match (Keeper_owner.projection owner).meta with
     | Some meta -> meta
     | None -> fail "Keeper metadata disappeared")
;;

let check_reclaimed ~config (operation : Keeper_shutdown_types.t) =
  match Keeper_shutdown_store.load ~config ~keeper_name:operation.keeper_name operation.operation_id with
  | Error (Keeper_shutdown_store.Not_found _) -> ()
  | Error error -> failf "record load failed: %s" (Keeper_shutdown_store.error_to_string error)
  | Ok retained -> failf "record was retained in phase %s" (phase_to_string retained.phase)
;;

let check_admission_released ~(config : Workspace.config) ~keeper_name =
  match Keeper_owner_registry.shutdown_operation_id ~base_path:config.base_path ~keeper_name with
  | Ok None -> ()
  | Ok (Some held) -> failf "admission still held by %s" (Operation_id.to_string held)
  | Error error -> failf "owner lookup failed: %s" (Keeper_owner_registry.lookup_error_to_string error)
;;

(* The case #38859 names. The latch is applied at boot, the operation
   finalizes, admission is released and the record is reclaimed. *)
let test_meta_update_operator_stop_is_replayed () =
  with_workspace (fun ~config ->
    let keeper_name = "blocked-replay-latch" in
    write_keeper_meta_exn ~config ~keeper_name ~trace:operation_trace;
    check bool "fixture Keeper starts unpaused" false (keeper_meta_exn ~config ~keeper_name).paused;
    let operation =
      make_operation ~keeper_name ~phase:latch_write_failed ~created_at:(Masc_domain.now_iso ())
    in
    persist_exn ~config operation;
    let recovered = recovered_exn (Keeper_shutdown_runtime.recover_at_boot ~config) operation in
    (match recovered.phase with
     | Finalized { completion = Completion_not_requested; meta_removed = false; _ } -> ()
     | phase -> failf "replay ended in %s instead of finalized" (phase_to_string phase));
    let meta = keeper_meta_exn ~config ~keeper_name in
    check bool "operator stop latch is applied" true meta.paused;
    check
      bool
      "latch names the operator stop"
      true
      (match meta.latched_reason with
       | Some (Keeper_latched_reason.Operator_paused _) -> true
       | Some _ | None -> false);
    check_admission_released ~config ~keeper_name;
    check_reclaimed ~config operation)
;;

(* The Keeper ran after the stop blocked: its trace moved on. Replaying the
   old snapshot would stop a different run, so the record is closed with a
   warning, reclaimed, and the Keeper is left as it is. *)
let test_trace_change_closes_instead_of_replaying () =
  with_workspace (fun ~config ->
    let keeper_name = "blocked-replay-trace-moved" in
    write_keeper_meta_exn ~config ~keeper_name ~trace:"trace-blocked-replay-later-run";
    let operation =
      make_operation ~keeper_name ~phase:latch_write_failed ~created_at:(Masc_domain.now_iso ())
    in
    persist_exn ~config operation;
    let recovered = recovered_exn (Keeper_shutdown_runtime.recover_at_boot ~config) operation in
    (match recovered.phase with
     | Superseded
         (Boot_replay_abandoned
            { blocked = { stage = Meta_update; _ }; abandonment = Keeper_trace_changed }) -> ()
     | phase -> failf "trace change ended in %s" (phase_to_string phase));
    check bool "Keeper is not paused by a stale stop" false (keeper_meta_exn ~config ~keeper_name).paused;
    check_admission_released ~config ~keeper_name;
    check_reclaimed ~config operation)
;;

(* A later operation exists for the same Keeper. Only the newest may act, so
   the older blocked stop is closed and reclaimed; the newer one keeps its
   own fence and is not disturbed. *)
let test_newer_operation_overtakes_blocked_stop () =
  with_workspace (fun ~config ->
    let keeper_name = "blocked-replay-overtaken" in
    write_keeper_meta_exn ~config ~keeper_name ~trace:operation_trace;
    let older =
      make_operation ~keeper_name ~phase:latch_write_failed ~created_at:"2026-09-01T00:00:00Z"
    in
    let newer =
      make_operation
        ~keeper_name
        ~phase:(Blocked { stage = Meta_remove; detail = "fixture: newer fenced failure" })
        ~created_at:"2026-09-02T00:00:00Z"
    in
    persist_exn ~config older;
    persist_exn ~config newer;
    let results = Keeper_shutdown_runtime.recover_at_boot ~config in
    let closed = recovered_exn results older in
    (match closed.phase with
     | Superseded (Boot_replay_abandoned { abandonment = Newer_operation by; _ }) ->
       check string "names the newer operation" (Operation_id.to_string newer.operation_id)
         (Operation_id.to_string by)
     | phase -> failf "older stop ended in %s" (phase_to_string phase));
    let kept = recovered_exn results newer in
    check bool "newer fenced operation keeps the fence" true (requires_admission_fence kept);
    check bool "Keeper is not paused by the overtaken stop" false (keeper_meta_exn ~config ~keeper_name).paused;
    check_reclaimed ~config older)
;;

let () =
  run
    "keeper_shutdown_blocked_replay"
    [ ( "boot replay"
      , [ test_case
            "Meta_update operator stop is replayed to the latch"
            `Quick
            test_meta_update_operator_stop_is_replayed
        ; test_case
            "trace change closes instead of replaying"
            `Quick
            test_trace_change_closes_instead_of_replaying
        ; test_case
            "newer operation overtakes a blocked stop"
            `Quick
            test_newer_operation_overtakes_blocked_stop
        ] )
    ]
;;
