open Keeper_gate_types
open Keeper_gate_authorization
open Keeper_gate_auto_judge_queue
open Keeper_gate_auto_judge_worker

open Result.Syntax

type recovered_work =
  | Activate_worker of Keeper_approval_queue_rules_types.pending_approval
  | Finalize_judgment of
      Keeper_approval_queue_rules_types.pending_approval
      * Keeper_approval_queue_rules_types.hitl_context_summary

(* Reclaim a start reservation orphaned by a hard restart: the graceful settle
   to identity-unbound runs only in memory, so a process death in the
   reserve->bind window strands the durable start-reserved row. Only a row this
   process does not hold a live admission for is reclaimed, so a reservation
   still in flight is never disturbed. On success the in-memory entry is
   advanced to ready so the caller's classification re-activates a worker. *)
let reclaim_orphaned_start_reservation
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  match entry.summary_attempt_disposition with
  | Keeper_approval_queue_rules_types.Summary_attempt_pre_worker_unavailable
      { reason_code =
          Keeper_approval_queue_rules_types.Summary_pre_worker_start_reserved
      ; _
      }
    when not (auto_judge_entry_claimed entry) ->
    (match
       Keeper_approval_queue.release_orphaned_start_reservation
         ~base_path:entry.audit_base_path
         ~id:entry.id
         ~input_hash:entry.input_hash
         ~sequence:entry.sequence
     with
     | Ok true ->
       Log.Keeper.warn
         ~keeper_name:entry.keeper_name
         "reclaimed orphaned Auto Judge start reservation approval=%s at boot \
          recovery"
         entry.id;
       { entry with
         summary_attempt_disposition =
           Keeper_approval_queue_rules_types.Summary_attempt_ready
       }
     | Ok false -> entry
     | Error error ->
       Log.Keeper.error
         ~keeper_name:entry.keeper_name
         "orphaned Auto Judge start reservation reclaim failed approval=%s: %s"
         entry.id
         (Keeper_approval_queue_result.exact_attempt_error_to_string error);
       entry)
  | Keeper_approval_queue_rules_types.Summary_attempt_pre_worker_unavailable { reason_code = (Keeper_approval_queue_rules_types.Summary_pre_worker_auto_judge_unavailable | Keeper_approval_queue_rules_types.Summary_pre_worker_mode_state_invalid);_}
  | Keeper_approval_queue_rules_types.Summary_attempt_ready
  | Keeper_approval_queue_rules_types.Summary_attempt_in_flight
  | Keeper_approval_queue_rules_types.Summary_attempt_identity_unbound
  | Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain
  | Keeper_approval_queue_rules_types.Summary_attempt_settled
  | Summary_attempt_pre_worker_unavailable {reason_code=Summary_pre_worker_start_reserved; _ } -> entry
;;

let recovered_work_for_base_path ~base_path =
  let* base_path =
    canonical_base_path base_path
    |> Result.map_error (fun reason ->
      ({ path = base_path; reason } : Keeper_approval_queue_result.storage_error))
  in
  (* Boot recovery admits owners by their EFFECTIVE mode, mirroring
     [drain_auto_judges]: a keeper override held in auto_judge above a
     manual/always_allow workspace must be recovered too, or restart —
     the only escape from a stalled owner — recovers nothing for it. *)
  let workspace_readable =
    match Keeper_gate_mode.read ~base_path with
    | Ok (_ : Keeper_gate_mode.t) -> true
    | Error detail ->
      Log.Keeper.error
        "Auto Judge recovery unavailable workspace=%s: %s"
        base_path
        detail;
      false
  in
  if not workspace_readable
  then Ok []
  else
    Keeper_approval_queue.list_pending_entries_for_workspace ~base_path
    |> Result.map (fun entries ->
    let entries = List.map reclaim_orphaned_start_reservation entries in
    let owners =
      List.fold_left
        (fun owners (entry : Keeper_approval_queue_rules_types.pending_approval) ->
           Auto_judge_owner_set.add (auto_judge_owner entry) owners)
        Auto_judge_owner_set.empty
        entries
    in
    let owners =
      Auto_judge_owner_set.filter
        (fun (owner_base_path, keeper_name) ->
           match
             Keeper_gate_mode.resolve ~base_path:owner_base_path ~keeper_name
           with
           | Ok Keeper_gate_mode.Auto_judge -> true
           | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow) ->
             false
           | Error detail ->
             Log.Keeper.error
               ~keeper_name
               "Auto Judge recovery owner mode unresolved workspace=%s: %s"
               owner_base_path
               detail;
             false)
        owners
    in
    let recovered_work_for_entry
          (entry : Keeper_approval_queue_rules_types.pending_approval)
      =
      match classify_auto_judge_entry entry with
      | Auto_judge_not_requested
      | Auto_judge_pending_unbound ->
        Some (Activate_worker entry)
      | Auto_judge_finalizable
          ({ judgment = (Keeper_approval_queue_rules_types.Approve | Keeper_approval_queue_rules_types.Deny); _ }
           as summary) ->
        Some (Finalize_judgment (entry, summary))
      | Auto_judge_finalizable
          { judgment = Keeper_approval_queue_rules_types.Require_human; _ }
      | Auto_judge_ineligible ->
        None
    in
    let entry_of_recovered_work = function
      | Activate_worker entry -> entry
      | Finalize_judgment (entry, _) -> entry
    in
    (* Per owner, admit worker-bound entries up to the available slots, but do
       not cross a finalizable exact-output row. That row is a durability
       barrier: its already-produced judgment must be fsync-confirmed before
       later provider work starts. Require_human and other ineligible rows are
       still passed over rather than becoming FIFO barriers. *)
    owners
    |> Auto_judge_owner_set.elements
    |> List.concat_map (fun (_, keeper_name) ->
      let available =
        Keeper_config.keeper_hitl_max_concurrent_per_keeper ()
        - List.length (active_auto_judges_for_owner ~base_path ~keeper_name)
        |> max 0
      in
      let rec select worker_slots selected = function
        | [] -> List.rev selected
        | entry :: rest ->
          (match recovered_work_for_entry entry with
           | Some (Finalize_judgment _ as work) ->
             if List.is_empty selected then [ work ] else List.rev selected
           | Some (Activate_worker _ as work) when worker_slots > 0 ->
             select (worker_slots - 1) (work :: selected) rest
           | Some (Activate_worker _) -> List.rev selected
           | None -> select worker_slots selected rest)
      in
      owner_auto_judges_in_fifo_order ~base_path ~keeper_name entries
      |> select available [])
    |> List.sort (fun left right ->
      compare_auto_judge_entries
        (entry_of_recovered_work left)
        (entry_of_recovered_work right)))
;;

let observe_recovered_work kind (entry : Keeper_approval_queue_rules_types.pending_approval) =
  let event_type, outcome =
    match kind with
    | `Activate_worker ->
      ( Keeper_approval.Audit.Auto_judge_restart_worker_recovered
      , "restart_worker_recovered" )
    | `Finalize_judgment ->
      ( Keeper_approval.Audit.Auto_judge_restart_judgment_recovered
      , "restart_judgment_recovered" )
  in
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "auto judge durable work recovered kind=%s approval=%s operation=%s"
    outcome
    entry.id
    entry.tool_name;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:[ "outcome", outcome ]
    ();
  ignore
    (Keeper_approval.Audit.record
       ~base_path:entry.audit_base_path
       ~event_type
       ~id:entry.id
       ~keeper_name:entry.keeper_name
       ~tool_name:entry.tool_name
       ?turn_id:entry.turn_id
       ?task_id:entry.task_id
       ?goal_id:entry.goal_id
       ())
;;

let rec retry_blocked_auto_judge
      ~base_path
      ~requested_by
      ~expected_input_hash
      ~expected_sequence
      ~expected_exact_attempt
      ~expected_disposition
      approval_id
  =
  Result.map_error
    auto_judge_retry_error_to_string
    (retry_blocked_auto_judge_typed
       ~base_path
       ~requested_by
       ~expected_input_hash
       ~expected_sequence
       ~expected_exact_attempt
       ~expected_disposition
       approval_id)

and retry_blocked_auto_judge_typed
      ~base_path
      ~requested_by
      ~expected_input_hash
      ~expected_sequence
      ~expected_exact_attempt
      ~expected_disposition
      approval_id
  =
  let* base_path =
    canonical_base_path base_path
    |> Result.map_error (fun detail -> Retry_mode_unreadable detail)
  in
  (* Same admission rule as [drain_auto_judges] (#31321): the entry's owner
     is judged by its EFFECTIVE mode, not the workspace mode alone. The old
     workspace-mode short-circuit refused this operator escape hatch for a
     keeper pinned to auto_judge under an always_allow or manual workspace —
     the exact stalled-owner configuration the retry exists for. The
     workspace read stays first so an unreadable mode store remains a loud
     error. *)
  match Keeper_gate_mode.read ~base_path with
  | Error detail -> Error (Retry_mode_unreadable detail)
  | Ok _workspace_mode ->
    (match
       Keeper_approval_queue.get_pending_entry_for_workspace
         ~base_path
         ~id:approval_id
     with
     | Error error -> Error (Retry_row_lookup_failed error)
     | Ok None -> Error (Retry_row_missing approval_id)
     | Ok (Some entry) ->
       (match
          let owner_base_path, keeper_name = auto_judge_owner entry in
          Keeper_gate_mode.resolve ~base_path:owner_base_path ~keeper_name
        with
        | Error detail -> Error (Retry_mode_unreadable detail)
        | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow) ->
          Error (Retry_not_auto_judge entry.keeper_name)
        | Ok Keeper_gate_mode.Auto_judge ->
       (match
          retry_auto_judge_entry
            ~requested_by
            ~expected_input_hash
            ~expected_sequence
            ~expected_exact_attempt
            ~expected_disposition
            entry
        with
        | Error reason -> Error reason
        | Ok Retry_skipped ->
          Error (Retry_not_blocked approval_id)
        | Ok Retry_started ->
          Log.Keeper.info
            ~keeper_name:entry.keeper_name
            "auto judge operator retry started approval=%s operation=%s actor=%s"
            entry.id
            entry.tool_name
            requested_by;
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string HitlSummaryOutcomes)
            ~labels:[ "outcome", "operator_retry_started" ]
            ();
       ignore
         (Keeper_approval.Audit.record
            ~base_path:entry.audit_base_path
            ~event_type:Keeper_approval.Audit.Auto_judge_operator_retry_started
            ~id:entry.id
            ~keeper_name:entry.keeper_name
            ~tool_name:entry.tool_name
            ?turn_id:entry.turn_id
            ?task_id:entry.task_id
            ?goal_id:entry.goal_id
            ~actor:requested_by
            ());
       Ok ())))
;;

let finalize_recovered_judgment
      ~complete_summary_exact_attempt
      (entry : Keeper_approval_queue_rules_types.pending_approval)
      summary
  =
  let persistence_uncertain () =
    ignore
      (Keeper_approval_queue.mark_summary_attempt_persistence_uncertain
         ~base_path:entry.audit_base_path
         ~id:entry.id
         ~input_hash:entry.input_hash
         ~sequence:entry.sequence
       : (bool, Keeper_approval_queue_result.exact_attempt_error) result)
  in
  match entry.exact_attempt with
  | Keeper_approval_queue_rules_types.Exact_unbound ->
    Error
      ( Resume_identity_unbound
      , "Recovered Auto Judge output has no exact attempt identity; finalization is withheld." )
  | Keeper_approval_queue_rules_types.Exact_bound
      ({ status = Keeper_approval_queue_rules_types.Exact_completed; _ } as binding) ->
    (match
       complete_summary_exact_attempt
         ~id:entry.id
         ~input_hash:entry.input_hash
         ~sequence:entry.sequence
         ~slot_id:binding.slot_id
         ~call_id:binding.call_id
         ~plan_fingerprint:binding.plan_fingerprint
         ~request_body_sha256:binding.request_body_sha256
         ~summary
     with
     | Ok
         { Keeper_approval_queue_result.write_outcome =
             Keeper_approval_queue_result.Fsync_completed
         ; _
          } ->
       (match resolve_judgment entry ~approval_id:entry.id summary with
        | Ok outcome -> Ok outcome
        | Error operator_detail ->
          Error (Resume_judgment_resolution_failed, operator_detail))
      | Ok
          { write_outcome =
              Keeper_approval_queue_result.Visible_sync_unconfirmed _detail
          ; _
          } ->
       persistence_uncertain ();
       Error
         ( Resume_completion_persistence_uncertain
         , "Exact completion is visible but durability is not confirmed; finalization is withheld." )
     | Error (Keeper_approval_queue_result.Exact_attempt_storage_error _error) ->
       persistence_uncertain ();
       Error
         ( Resume_completion_persistence_uncertain
         , "Exact completion durability is not confirmed; finalization is withheld." )
     | Error (Keeper_approval_queue_result.Exact_attempt_rejected rejection) ->
       let rejection = completion_rejection_of_exact_attempt rejection in
       Error
         ( Resume_completion_rejected rejection
         , completion_rejection_operator_detail rejection ))
  | Keeper_approval_queue_rules_types.Exact_bound
      { status =
          ( Keeper_approval_queue_rules_types.Exact_dispatch_uncertain
          | Keeper_approval_queue_rules_types.Exact_released_before_dispatch
          | Keeper_approval_queue_rules_types.Exact_released_recovery_required
          | Keeper_approval_queue_rules_types.Exact_quarantined _
          | Keeper_approval_queue_rules_types.Exact_restart_quarantined )
      ; _
      } ->
    Error
      ( Resume_exact_state_not_completed
      , "Recovered Auto Judge entry is not a completed exact judgment." )
;;

let resume_persisted_auto_judges_with
      ~complete_summary_exact_attempt
      ~base_path
  =
  match recovered_work_for_base_path ~base_path with
  | Error queue_error ->
    { requested = 0
    ; started_ids = []
    ; finalized_ids = []
    ; skipped_ids = []
    ; failures = []
    ; queue_error = Some queue_error
    }
  | Ok recovered ->
    let requested = List.length recovered in
    let started_ids, finalized_ids, skipped_ids, failures =
      List.fold_left
        (fun (started_ids, finalized_ids, skipped_ids, failures) work ->
         let entry, result =
           match work with
           | Activate_worker entry ->
             observe_recovered_work `Activate_worker entry;
             entry, `Start (start_auto_judge_entry entry)
             | Finalize_judgment (entry, summary) ->
               observe_recovered_work `Finalize_judgment entry;
               ( entry
               , `Finalize
                   (finalize_recovered_judgment
                      ~complete_summary_exact_attempt
                      entry
                      summary) )
         in
         match result with
         | `Start (Ok Started) ->
           entry.id :: started_ids, finalized_ids, skipped_ids, failures
         | `Finalize (Ok Judgment_finalized) ->
           started_ids, entry.id :: finalized_ids, skipped_ids, failures
         | `Start (Ok Skipped) | `Finalize (Ok Judgment_skipped) ->
           started_ids, finalized_ids, entry.id :: skipped_ids, failures
         | `Start (Error reason) ->
           ( started_ids
           , finalized_ids
           , skipped_ids
           , { approval_id = entry.id
             ; code = Resume_worker_start_failed
             ; operator_detail = reason
             }
             :: failures )
         | `Finalize (Error (code, operator_detail)) ->
           ( started_ids
           , finalized_ids
           , skipped_ids
           , { approval_id = entry.id; code; operator_detail } :: failures ))
        ([], [], [], [])
        recovered
    in
    { requested
    ; started_ids = List.rev started_ids
    ; finalized_ids = List.rev finalized_ids
    ; skipped_ids = List.rev skipped_ids
    ; failures = List.rev failures
    ; queue_error = None
    }
;;

let resume_persisted_auto_judges =
  resume_persisted_auto_judges_with
    ~complete_summary_exact_attempt:
      Keeper_approval_queue.complete_summary_exact_attempt
;;

type operator_recovery_report =
  { started_ids : string list
  ; queued : int
  ; failures : auto_judge_owner_failure list
  ; blockers : auto_judge_owner_blocker list
  }

let request_operator_auto_judge_recovery ~base_path =
  let* base_path = canonical_base_path base_path in
  (* [drain_auto_judges] already admits owners by their EFFECTIVE mode
     (#31321), so refusing here on the workspace mode alone re-closed the
     escape hatch for a keeper pinned to auto_judge under an always_allow
     or manual workspace. The workspace read stays as the loud
     unreadable-store check; a workspace where no owner resolves to
     auto_judge simply drains zero entries, and the report says so. *)
  match Keeper_gate_mode.read ~base_path with
  | Error detail -> Error detail
  | Ok _workspace_mode ->
    (match Hitl_summary_worker.snapshot_topology_readiness () with
     | Error detail -> Error detail
     | Ok () ->
       (match drain_auto_judges ~base_path with
       | Error detail -> Error detail
       | Ok drain_report ->
          (match
             Keeper_approval_queue.list_pending_entries_for_workspace ~base_path
           with
           | Error error ->
             Error (Keeper_approval_queue_result.storage_error_to_string error)
           | Ok entries ->
             let queued =
               List.fold_left
                 (fun count (entry : Keeper_approval_queue_rules_types.pending_approval) ->
                    if auto_judge_entry_ready entry then count + 1 else count)
                 0
                 entries
             in
             Ok
               { started_ids = drain_report.started_ids
               ; queued
               ; failures = drain_report.failures
               ; blockers = drain_report.blockers
               })))
;;
