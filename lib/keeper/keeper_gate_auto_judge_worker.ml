open Keeper_gate_auto_judge_queue

let log_auto_resolution_error ~keeper_name ~approval_id reason =
  Log.Keeper.warn
    ~keeper_name
    "auto judge resolution failed approval=%s: %s"
    approval_id
    reason
;;

type hitl_worker_spawner =
  sw:Eio.Switch.t ->
  entry:Keeper_approval_queue_rules_types.pending_approval ->
  on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit) ->
  on_finish:(Hitl_summary_worker.finish_outcome -> unit) ->
  unit ->
  (Hitl_summary_worker.spawn_outcome, string) result

let mark_pre_worker_unavailable
      (entry : Keeper_approval_queue_rules_types.pending_approval)
      ~reason_code
      ~operator_detail
  =
  Keeper_approval_queue.mark_summary_attempt_pre_worker_unavailable
    ~base_path:entry.audit_base_path
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~reason_code
    ~operator_detail
;;

let durable_pre_worker_unavailable_error reason = function
  | Ok true -> reason
  | Ok false ->
    reason ^ "; durable pre-worker blocked observation was not applied"
  | Error error ->
    reason
    ^ "; durable pre-worker blocked observation failed: "
    ^ Keeper_approval_queue_result.exact_attempt_error_to_string error
;;

let reserve_pre_worker_start
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  match
    mark_pre_worker_unavailable
      entry
      ~reason_code:Keeper_approval_queue_rules_types.Summary_pre_worker_start_reserved
      ~operator_detail:
        Keeper_approval_queue_result.summary_attempt_start_reserved_operator_detail
  with
  | Ok true -> Ok ()
  | Ok false ->
    Error "Auto Judge worker start reservation was not applied"
  | Error error ->
    Error
      ("Auto Judge worker start reservation failed: "
       ^ Keeper_approval_queue_result.exact_attempt_error_to_string error)
;;

let rec run_reserved_auto_judge_entry_with
      ~(spawn_worker : hitl_worker_spawner)
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  let approval_id = entry.id in
  let on_summary summary =
    match resolve_judgment entry ~approval_id summary with
    | Ok (Judgment_finalized | Judgment_skipped) -> ()
    | Error reason ->
      log_auto_resolution_error
        ~keeper_name:entry.keeper_name
        ~approval_id
        reason
  in
  let fail_before_worker ~reason =
    Fun.protect
      ~finally:(fun () -> release_auto_judge entry)
      (fun () ->
         mark_pre_worker_unavailable
           entry
           ~reason_code:
             Keeper_approval_queue_rules_types.Summary_pre_worker_auto_judge_unavailable
           ~operator_detail:reason
         |> durable_pre_worker_unavailable_error reason
         |> Result.error)
  in
  let start_after_reservation () =
  match Eio_context.get_root_switch_opt () with
  | Some sw ->
    (try
       match
         spawn_worker
           ~sw
           ~entry
           ~on_summary
           ~on_finish:(fun finish_outcome ->
             release_auto_judge entry;
             match finish_outcome with
             | Hitl_summary_worker.Conclusive_terminalization ->
               ignore
                 (drain_auto_judge_owner
                    ~base_path:entry.audit_base_path
                    ~keeper_name:entry.keeper_name
                    ())
             | Hitl_summary_worker.Terminalization_identity_unbound ->
               Log.Keeper.warn
                 ~keeper_name:entry.keeper_name
                 "Auto Judge terminalization blocked before exact attempt identity was bound; durable pending approval retained approval=%s"
                 entry.id
             | Hitl_summary_worker.Terminalization_persistence_uncertain ->
               Log.Keeper.error
                 ~keeper_name:entry.keeper_name
                 "Auto Judge owner drain withheld after persistence uncertainty \
                  approval=%s"
                 entry.id
             | Hitl_summary_worker.Terminalization_rejected ->
               Log.Keeper.warn
                 ~keeper_name:entry.keeper_name
                 "Auto Judge owner drain withheld after deterministic exact-attempt rejection approval=%s"
                 entry.id
             )
           ()
       with
       | Ok Hitl_summary_worker.Worker_forked -> Ok Started
       | Error reason -> fail_before_worker ~reason
     with
     | Eio.Cancel.Cancelled _ as exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       let reason =
         "Auto Judge worker start was cancelled: " ^ Printexc.to_string exn
       in
       Eio.Cancel.protect (fun () ->
         match fail_before_worker ~reason with
         | Ok _ | Error _ -> ());
       Printexc.raise_with_backtrace exn backtrace
     | exn ->
       let reason =
         "Auto Judge worker start failed: " ^ Printexc.to_string exn
       in
       fail_before_worker ~reason)
  | None ->
    fail_before_worker
      ~reason:"Auto Judge unavailable: server root switch is not installed"
  in
  start_after_reservation ()

and spawn_claimed_auto_judge_entry_with
      ~(spawn_worker : hitl_worker_spawner)
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  match reserve_pre_worker_start entry with
  | Ok () -> run_reserved_auto_judge_entry_with ~spawn_worker entry
  | Error reason ->
    release_auto_judge entry;
    Error reason

and spawn_claimed_auto_judge_entry_detached_with
      ~(spawn_worker : hitl_worker_spawner)
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  match reserve_pre_worker_start entry with
  | Error reason ->
    release_auto_judge entry;
    Error reason
  | Ok () ->
    (match Eio_context.get_root_switch_opt () with
     | None ->
       let reason = "Auto Judge unavailable: server root switch is not installed" in
       let reason =
         mark_pre_worker_unavailable
           entry
           ~reason_code:
             Keeper_approval_queue_rules_types
             .Summary_pre_worker_auto_judge_unavailable
           ~operator_detail:reason
         |> durable_pre_worker_unavailable_error reason
       in
       release_auto_judge entry;
       Error reason
     | Some sw ->
       (try
          Eio.Fiber.fork ~sw (fun () ->
            match run_reserved_auto_judge_entry_with ~spawn_worker entry with
            | Ok _ -> ()
            | Error reason ->
              Log.Keeper.error
                ~keeper_name:entry.keeper_name
                "Auto Judge detached worker start failed approval=%s: %s"
                entry.id
                reason);
          Ok Started
        with
        | Eio.Cancel.Cancelled _ as exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          let reason =
            "Auto Judge detached worker launch was cancelled: "
            ^ Printexc.to_string exn
          in
          Eio.Cancel.protect (fun () ->
            ignore
              (mark_pre_worker_unavailable
                 entry
                 ~reason_code:
                   Keeper_approval_queue_rules_types
                   .Summary_pre_worker_auto_judge_unavailable
                 ~operator_detail:reason);
            release_auto_judge entry);
          Printexc.raise_with_backtrace exn backtrace
        | exn ->
          let reason =
            "Auto Judge detached worker launch failed: " ^ Printexc.to_string exn
          in
          let reason =
            mark_pre_worker_unavailable
              entry
              ~reason_code:
                Keeper_approval_queue_rules_types
                .Summary_pre_worker_auto_judge_unavailable
              ~operator_detail:reason
            |> durable_pre_worker_unavailable_error reason
          in
          release_auto_judge entry;
          Error reason))

and spawn_claimed_auto_judge_entry entry =
  spawn_claimed_auto_judge_entry_detached_with
    ~spawn_worker:Hitl_summary_worker.spawn
    entry

and spawn_auto_judge_entry_with
      ~(spawn_worker : hitl_worker_spawner)
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  if claim_auto_judge entry
  then spawn_claimed_auto_judge_entry_with ~spawn_worker entry
  else Ok Skipped

and spawn_auto_judge_entry entry =
  if claim_auto_judge entry
  then
    spawn_claimed_auto_judge_entry_detached_with
      ~spawn_worker:Hitl_summary_worker.spawn
      entry
  else Ok Skipped

and retry_auto_judge_entry
      ~requested_by
      ~expected_input_hash
      ~expected_sequence
      ~expected_exact_attempt
      ~expected_disposition
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  match
    Keeper_approval_queue.reserve_summary_attempt_retry
      ~base_path:entry.audit_base_path
      ~id:entry.id
      ~input_hash:expected_input_hash
      ~sequence:expected_sequence
      ~expected_exact_attempt
      ~expected_disposition
      ~requested_by
  with
  | Error error -> Error (Retry_cas_rejected error)
  | Ok false -> Ok Retry_skipped
  | Ok true ->
    let reblock reason =
      mark_pre_worker_unavailable
        entry
        ~reason_code:
          Keeper_approval_queue_rules_types.Summary_pre_worker_auto_judge_unavailable
        ~operator_detail:reason
      |> durable_pre_worker_unavailable_error reason
    in
    (try
       match
         drain_auto_judge_owner
           ~reserved_id:entry.id
           ~base_path:entry.audit_base_path
           ~keeper_name:entry.keeper_name
           ()
       with
       | Error reason -> Error (Retry_drain_failed (reblock reason))
       | Ok (outcome : auto_judge_drain_outcome) ->
         (match
            List.assoc_opt entry.id outcome.failures,
            List.mem entry.id outcome.started_ids,
            outcome.started_ids,
            outcome.blocker
          with
          | Some reason, _, _, _ ->
            Error (Retry_drain_failed (reblock reason))
          | None, true, _, _ -> Ok Retry_started
          | None, false, started_id :: _, _ ->
            Error
              (Retry_drain_failed
                 (reblock
                    (Printf.sprintf
                       "Auto Judge retry could not start because earlier approval %s acquired the owner"
                       started_id)))
          | None, false, [], Some blocker ->
            Error
              (Retry_drain_failed
                 (reblock (auto_judge_drain_blocker_to_string blocker)))
          | None, false, [], None ->
            Error
              (Retry_drain_failed
                 (reblock
                    "Auto Judge retry drain completed without a start or blocker")))
     with
     | Eio.Cancel.Cancelled _ as exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       let reason =
         "Auto Judge retry was cancelled before exact attempt binding: "
         ^ Printexc.to_string exn
       in
       let _reblocked_reason =
         Eio.Cancel.protect (fun () -> reblock reason)
       in
       Printexc.raise_with_backtrace exn backtrace
     | exn ->
       let reason =
         "Auto Judge retry failed before exact attempt binding: "
         ^ Printexc.to_string exn
       in
       Error (Retry_drain_failed (reblock reason)))

and start_auto_judge (entry : Keeper_approval_queue_rules_types.pending_approval) =
  if not (claim_auto_judge entry)
  then Ok Skipped
  else
    match Keeper_approval_queue.mark_summary_pending ~id:entry.id with
    | Error error ->
      release_auto_judge entry;
      Error (Keeper_approval_queue_result.summary_transition_error_to_string error)
    | Ok false ->
      release_auto_judge entry;
      Ok Skipped
    | Ok true -> spawn_claimed_auto_judge_entry entry

and start_auto_judge_entry (entry : Keeper_approval_queue_rules_types.pending_approval) =
  match
    Keeper_approval_queue.get_pending_entry_for_workspace
      ~base_path:entry.audit_base_path
      ~id:entry.id
  with
  | Error error ->
    Error (Keeper_approval_queue_result.storage_error_to_string error)
  | Ok None -> Ok Skipped
  | Ok (Some current) ->
    (match classify_auto_judge_entry current with
     | Auto_judge_not_requested -> start_auto_judge current
     | Auto_judge_pending_unbound -> spawn_auto_judge_entry current
     | Auto_judge_finalizable _
     | Auto_judge_ineligible ->
       Ok Skipped)

and drain_auto_judge_owner_queue
      ?reserved_id
      ~base_path
      ~keeper_name
      ()
  =
  let rec loop started_ids failures blocker = function
    | [] ->
      { started_ids = List.rev started_ids
      ; failures = List.rev failures
      ; blocker
      }
    | entry :: rest ->
      let start_result =
        match reserved_id with
        | Some reserved_id
          when auto_judge_entry_has_start_reservation reserved_id entry ->
          spawn_auto_judge_entry entry
        | Some _ | None -> start_auto_judge_entry entry
      in
      (match start_result with
       | Ok Started ->
         loop (entry.id :: started_ids) failures None rest
       | Ok Skipped ->
         let active_ids =
           active_auto_judges_for_owner ~base_path ~keeper_name
         in
         if
           List.length active_ids
           >= Keeper_config.keeper_hitl_max_concurrent_per_keeper ()
         then
            { started_ids = List.rev started_ids
            ; failures = List.rev failures
            ; blocker = Some (Drain_owner_at_capacity active_ids)
            }
         else
           loop
             started_ids
             failures
             (Some (Drain_entry_changed entry.id))
             rest
       | Error reason ->
         Log.Keeper.error
           ~keeper_name
           "Auto Judge owner drain failed approval=%s: %s"
           entry.id
           reason;
         loop
           started_ids
           ((entry.id, reason) :: failures)
           (Some (Drain_start_failed (entry.id, reason)))
           rest)
  in
  Keeper_approval_queue.list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    let selected =
      ready_auto_judges_for_owner
        ?reserved_id
        ~base_path
        ~keeper_name
        entries
    in
    (* Selection ranges over every startable entry, so an empty selection under
       a reservation means the reserved entry itself is no longer startable --
       never that an earlier approval holds the FIFO head. *)
    let active_ids = active_auto_judges_for_owner ~base_path ~keeper_name in
    let at_capacity =
      List.length active_ids
      >= Keeper_config.keeper_hitl_max_concurrent_per_keeper ()
    in
    let blocker =
      match reserved_id, selected with
      | _, [] when at_capacity -> Some (Drain_owner_at_capacity active_ids)
      | Some reserved_id, [] ->
        (match
           List.exists
             (fun (entry : Keeper_approval_queue_rules_types.pending_approval) ->
                String.equal entry.id reserved_id)
             entries
         with
         | false -> Some (Drain_entry_missing reserved_id)
         | true -> Some (Drain_entry_changed reserved_id))
      | _ -> None
    in
    loop [] [] blocker selected)

and drain_auto_judge_owner
      ?reserved_id
      ~base_path
      ~keeper_name
      ()
  =
  match Keeper_gate_mode.resolve ~base_path ~keeper_name with
  | Ok Keeper_gate_mode.Auto_judge ->
    drain_auto_judge_owner_queue
      ?reserved_id
      ~base_path
      ~keeper_name
      ()
    |> Result.map_error Keeper_approval_queue_result.storage_error_to_string
  | Ok Keeper_gate_mode.Manual ->
    Ok
      { started_ids = []
      ; failures = []
      ; blocker = Some Drain_mode_manual
      }
  | Ok Keeper_gate_mode.Always_allow ->
    Ok
      { started_ids = []
      ; failures = []
      ; blocker = Some Drain_mode_always_allow
      }
  | Error detail ->
    Log.Keeper.error
      ~keeper_name
      "Auto Judge owner drain unavailable workspace=%s: %s"
      base_path
      detail;
    Error detail

and drain_auto_judges ~base_path =
  (* The sweep admits owners by their EFFECTIVE mode, not by the workspace
     mode alone. A stricter keeper override can hold one keeper in
     auto_judge while the workspace sits in manual or always_allow — the
     old workspace-mode short-circuit left that keeper's approvals queued
     with nothing sweeping them (the hazard keeper_gate_mode.ml's
     strictness comment predicted for the loosening direction, reached
     from the stricter one). The same filter also stops sweeping an owner
     a manual override holds ABOVE an auto_judge workspace, which the old
     branch judged strictly but drained anyway. The workspace read stays
     first so an unreadable mode store remains a loud error, not an empty
     sweep. *)
  match Keeper_gate_mode.read ~base_path with
  | Error detail ->
    Log.Keeper.error
      "Auto Judge workspace drain unavailable workspace=%s: %s"
      base_path
      detail;
    Error detail
  | Ok (_ : Keeper_gate_mode.t) ->
    (match Keeper_approval_queue.list_pending_entries_for_workspace ~base_path with
     | Error error ->
       Error (Keeper_approval_queue_result.storage_error_to_string error)
     | Ok entries ->
       let owners =
         List.fold_left
           (fun owners (entry : Keeper_approval_queue_rules_types.pending_approval) ->
              if auto_judge_entry_ready entry
              then Auto_judge_owner_set.add (auto_judge_owner entry) owners
              else owners)
           Auto_judge_owner_set.empty
           entries
       in
       let auto_judge_owners =
         List.filter
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
                  "Auto Judge drain owner mode unresolved workspace=%s: %s"
                  owner_base_path
                  detail;
                false)
           (Auto_judge_owner_set.elements owners)
       in
       Ok
         (drain_auto_judge_owners_with
            ~drain_owner:(fun ~base_path ~keeper_name ->
              drain_auto_judge_owner_queue ~base_path ~keeper_name ()
              |> Result.map
                   (fun (outcome : auto_judge_drain_outcome) ->
                      outcome.started_ids, outcome.failures, outcome.blocker)
              |> Result.map_error
                   Keeper_approval_queue_result.storage_error_to_string)
            auto_judge_owners))
;;
