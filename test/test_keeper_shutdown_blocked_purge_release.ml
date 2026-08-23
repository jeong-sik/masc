(* A dashboard purge whose worker died in [Joining_lanes] is recovered as
   [Blocked Lane_join], which keeps the admission fence. Nothing then moved it:
   the fence stopped the Keeper's meta being materialized, [resolve] needs that
   meta to build a purge target, and supersession admitted no intent but
   [Operator_stop_retain_meta]. Three keepers sat half-purged from 2026-08-19,
   with reconcile re-attempting ~238 times an hour and the dashboard answering
   every retry with "accepted" — the same no-exit shape #25491 fixed for
   [Reconciliation_required], reached through a different pair. *)

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
  let base = temp_dir "keeper_shutdown_blocked_purge_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Fun.protect
         ~finally:(fun () -> Fs_compat.clear_fs ())
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

let keeper_name = "rw-e0-blocked-purge"

let purge_intent =
  { reason =
      Dashboard_keeper_purge
        { requested_name = keeper_name
        ; agent_name = Printf.sprintf "keeper-%s-agent" keeper_name
        }
  ; remove_session = true
  }
;;

let stop_intent = { reason = Operator_stop_retain_meta; remove_session = false }

let interrupted_lane_join =
  Blocked
    { stage = Lane_join
    ; detail = "server process ended while joining Keeper and Librarian lanes"
    }
;;

let make_operation ~cleanup_intent ~phase =
  { schema_version = Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id = Operation_id.generate ()
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id = trace_id_exn "trace-blocked-purge-release-test"
  ; actor = "dashboard"
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

let release_exn ~config operation =
  match
    Keeper_shutdown_store.prepare_operator_metadata_supersession
      ~config
      ~keeper_name
      ~operation_id:operation.operation_id
      ~actor:"operator"
  with
  | Error error ->
    failf
      "blocked purge refused a supersession token: %s"
      (Keeper_shutdown_store.error_to_string error)
  | Ok token ->
    (match
       Keeper_shutdown_store.supersede_blocked_operator_stop
         ~config
         ~token
         ~now:Masc_domain.now_iso
     with
     | Ok (Superseded_persisted released | Superseded_already_persisted released) ->
       released
     | Error error ->
       failf
         "supersession did not persist: %s"
         (Keeper_shutdown_store.error_to_string error))
;;

(* The fence is the whole wedge: while it is held nothing else can move, so a
   release that only rewrites the phase would leave the Keeper exactly as
   stuck. *)
let test_release_frees_the_admission_fence () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    check bool "a blocked purge holds the fence" true
      (requires_admission_fence operation);
    let released = release_exn ~config operation in
    check bool "the release frees it" false (requires_admission_fence released))
;;

(* The durable record has to say which release was signed off. Recording a
   purge release as [Operator_metadata_update] would claim an operator updated
   metadata that a purge deletes. *)
let test_release_is_recorded_as_a_purge_release () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let released = release_exn ~config operation in
    match released.phase with
    | Superseded (Operator_blocked_purge_released { actor }) ->
      check string "records the operator" "operator" actor
    | Superseded (Operator_metadata_update _) ->
      fail "a purge release was recorded as a metadata update"
    | Superseded (Operator_reconciliation_accepted _) ->
      fail "a purge release was recorded as a reconciliation acceptance"
    | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _ | Cleanup_ready _
    | Reconciliation_required _ | Finalized _ | Blocked _ ->
      fail "the blocked purge was not superseded")
;;

(* Reloading proves the new supersession survives the codec: a release that
   cannot be read back reappears as [Blocked] on the next boot. *)
let test_release_survives_a_reload () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let (_released : Keeper_shutdown_types.t) = release_exn ~config operation in
    match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
    | Error error ->
      failf "released purge did not load: %s" (Keeper_shutdown_store.error_to_string error)
    | Ok reloaded ->
      (match reloaded.phase with
       | Superseded (Operator_blocked_purge_released _) ->
         check bool "still unfenced after a reload" false
           (requires_admission_fence reloaded)
       | _ -> fail "the reloaded phase was not a purge release"))
;;

(* The release exists for a purge, so it must not become a way around the
   metadata-update route: an operator stop still records its own supersession. *)
let test_operator_stop_release_is_unchanged () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:stop_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let released = release_exn ~config operation in
    match released.phase with
    | Superseded (Operator_metadata_update _) -> ()
    | Superseded (Operator_blocked_purge_released _) ->
      fail "an operator stop was recorded as a purge release"
    | _ -> fail "the blocked operator stop was not superseded")
;;

let () =
  run
    "keeper-shutdown-blocked-purge-release"
    [ ( "operator release"
      , [ test_case "frees the admission fence" `Quick test_release_frees_the_admission_fence
        ; test_case
            "is recorded as a purge release"
            `Quick
            test_release_is_recorded_as_a_purge_release
        ; test_case "survives a reload" `Quick test_release_survives_a_reload
        ; test_case
            "leaves the operator-stop route alone"
            `Quick
            test_operator_stop_release_is_unchanged
        ] )
    ]
;;
