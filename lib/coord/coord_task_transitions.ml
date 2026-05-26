(* * Coord_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next. *)
open Masc_domain
include Coord_utils
include Coord_state
include Coord_broadcast
open Coord_backlog
(* Sub-module includes — re-export all bindings from extracted modules. *)
include Coord_task_classify
include Coord_task_create
include Coord_task_claim
let transition_task_r
      config
      ~agent_name
      ~task_id
      ~action
      ?agent_tool_names
      ?prepare_verification_request
      ?prepare_verification_verdict
      ?expected_version
      ?(notes = "")
      ?(reason = "")
      ?handoff_context
      ?(force = false)
      ()
  : string Masc_domain.masc_result
  =
  let open Result.Syntax in
  let* () =
    if not (is_initialized config)
    then Error (Masc_domain.System Masc_domain.System_error.NotInitialized)
    else Ok ()
  in
  let* () =
    match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ -> Ok ()
  in
(* BUG-006: Resolve agent name to canonical form (e.g. *)
  let agent_name = resolve_agent_name_strict config agent_name in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock_r config backlog_path (fun () ->
    try
      match read_backlog_r config with
      | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
      | Ok backlog ->
        let* () =
          match expected_version with
          | Some v when backlog.version <> v ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "Version mismatch (expected %d, got %d)"
                       v
                       backlog.version)))
          | _ -> Ok ()
        in
        let task_opt = List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks in
        let* task =
          match task_opt with
          | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
          | Some task -> Ok task
        in
        let* () =
          match action with
          | Masc_domain.Claim ->
            required_tool_claim_guard config ~agent_name ?agent_tool_names task
          | Masc_domain.Release
          | Masc_domain.Start
          | Masc_domain.Submit_for_verification
          | Masc_domain.Submit_pr_evidence
          | Masc_domain.Approve_verification
          | Masc_domain.Reject_verification
          | Masc_domain.Done_action
          | Masc_domain.Cancel -> Ok ()
        in
        let* () =
          match action, Masc_domain.task_reclaim_gate task with
          | Masc_domain.Claim, Reclaim_gate_blocked_by_policy r ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf "Task %s is blocked from re-claim: %s" task_id r)))
          | Masc_domain.Claim, Reclaim_gate_open
          | ( Masc_domain.Start | Masc_domain.Done_action | Masc_domain.Cancel
            | Masc_domain.Release | Masc_domain.Submit_for_verification
            | Masc_domain.Approve_verification | Masc_domain.Reject_verification
            | Masc_domain.Submit_pr_evidence ), _ -> Ok ()
        in
        let* () =
          (match action, task.task_status with
          | Masc_domain.Claim, Masc_domain.Todo ->
            (match
               active_ownership_conflict_for_claim
                 config
                 ~agent_name
                 ~requested_task_id:task_id
                 backlog
             with
             | None -> Ok ()
             | Some msg ->
               Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)))
          | ( Masc_domain.Claim
            | Masc_domain.Start
            | Masc_domain.Done_action
            | Masc_domain.Cancel
            | Masc_domain.Release
            | Masc_domain.Submit_for_verification
            | Masc_domain.Submit_pr_evidence
            | Masc_domain.Approve_verification
            | Masc_domain.Reject_verification ), _ -> Ok ())
          [@warning "-4"]
        in
        let now = now_iso () in
        let now_ts = Time_compat.now () in
        let action_s = Masc_domain.task_action_to_string action in
        let* decision =
          match
            Coord_task_lifecycle.decide
              ~verification_enabled:(Env_config_runtime.Verification.fsm_enabled ())
              ~verification_timeout_seconds:
                (Env_config_runtime.Verification.timeout_deadline_seconds ())
              ~new_verification_id:(fun () -> Random_id.prefixed ~prefix:"vrf-" ~bytes:16)
              ~same_agent:(same_task_actor config agent_name)
              ~agent_name
              ~task_id
              ~task_status:task.task_status
              ~action
              ~now
              ~force
              ~notes
              ~reason
          with
          | Ok decision -> Ok decision
          | Error Coord_task_lifecycle.Self_approval ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Self-approval not allowed: verifier must be a different agent"))
          | Error Coord_task_lifecycle.Self_rejection ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Self-rejection not allowed: verifier must be a different agent"))
          | Error Coord_task_lifecycle.Verification_disabled ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Verification FSM not enabled (MASC_VERIFICATION_FSM_ENABLED=false)"))
          | Error Coord_task_lifecycle.Invalid_transition ->
            let assignee_hint =
              match task_assignee_of_status task.task_status with
              | Some a when not (same_task_actor config a agent_name) ->
                Printf.sprintf ", current_assignee=%s" a
              | _ -> ""
            in
(* Issue #7646: ownership-mismatch dominates; only show valid_next_actions when the failure isn't an ownership problem. *)
            let actions_hint =
              if assignee_hint <> "" then "" else next_actions_hint task.task_status
            in
(* Concrete remediation. *)
(* WORKAROUND: task_status (6 ctors) × task_action (9 ctors) = 54 combos, with ~11 specific hint cases. *)
            let[@warning "-4"] remediation =
              let own_assignee =
                match task_assignee_of_status task.task_status with
                | Some a when same_task_actor config a agent_name -> true
                | _ -> false
              in
              match task.task_status, action with
              | Masc_domain.Todo, Masc_domain.Release ->
                " Remediation: task is still in 'todo'. Call masc_transition \
                 action=claim first, then action=release once you own it."
              | Masc_domain.Todo, (Masc_domain.Done_action | Masc_domain.Cancel) ->
                " Remediation: task is still in 'todo'. Call masc_transition \
                 action=claim then action=start before trying to finish or cancel it."
              | Masc_domain.Todo, Masc_domain.Start ->
                " Remediation: task is still in 'todo'. Call masc_transition \
                 action=claim first — start needs ownership."
              | Masc_domain.Claimed _, Masc_domain.Release when not own_assignee ->
                " Remediation: this task is claimed by another keeper. Use \
                 masc_board_post to ask that agent to release/hand off, or claim a \
                 different task with masc_claim_next."
              | Masc_domain.Claimed _, Masc_domain.Done_action when not own_assignee ->
                " Remediation: only the current assignee can mark a task done. Pick a \
                 different task or coordinate via masc_board_post."
              | (Masc_domain.Claimed _ | Masc_domain.InProgress _), Masc_domain.Cancel
                when not own_assignee ->
                " Remediation: cancellation requires owning the task. Use \
                 masc_board_post to ask the current assignee to cancel or release, or \
                 claim a different task with masc_claim_next."
              | Masc_domain.InProgress _, Masc_domain.Claim ->
                " Remediation: task is already in_progress under someone. Use \
                 masc_claim_next for unclaimed work."
              | Masc_domain.Done _, _ ->
                " Remediation: task is already in a terminal state (done). Use \
                 masc_add_task for new work or masc_tasks to find claimable items."
              | Masc_domain.Cancelled _, _ ->
                " Remediation: task is already cancelled. Use masc_add_task for new work \
                 or masc_tasks to find claimable items."
              | _ -> ""
            in
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "Invalid transition: %s -> %s (%s, agent=%s%s%s).%s"
                       (task_status_to_string task.task_status)
                       action_s
                       task_id
                       agent_name
                       assignee_hint
                       actions_hint
                       remediation)))
        in
        let new_status = decision.Coord_task_lifecycle.new_status in
        let set_current = decision.set_current in
(* WORKAROUND: action (9) × task_status (6) × new_status (6) × option (2) = 648 combos. *)
        let* () =
          (match action, task.task_status, new_status, prepare_verification_request with
          | ( (Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence)
            , _
            , Masc_domain.AwaitingVerification { assignee; verification_id; _ }
            , prepare_opt ) ->
            let evidence_refs =
              Coord_task_verification.verification_submission_evidence_refs task ~notes handoff_context
            in
            if evidence_refs = [] then
              Error
                (Masc_domain.Task
                   (Masc_domain.Task_error.InvalidState
                      Coord_task_verification.verification_evidence_error_message))
            else
              (match prepare_opt with
               | None -> Ok ()
               | Some prepare ->
                 (match prepare ~task ~assignee ~verification_id ~evidence_refs with
                  | Ok () -> Ok ()
                  | Error e ->
                    Error
                      (Masc_domain.System
                         (Masc_domain.System_error.IoError
                            (Printf.sprintf
                               "verification request creation failed before status transition \
                                (task=%s vrf=%s): %s"
                               task_id
                               verification_id
                               e)))))
          | ( (Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence)
            , _
            , _
            , Some _ ) ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "submit_for_verification did not produce AwaitingVerification for \
                        task %s"
                       task_id)))
          | ( ( Masc_domain.Claim
              | Masc_domain.Start
              | Masc_domain.Done_action
              | Masc_domain.Cancel
              | Masc_domain.Release
              | Masc_domain.Approve_verification
              | Masc_domain.Reject_verification )
            , _
            , _
            , Some _ ) -> Ok ()
          | ( ( Masc_domain.Claim
              | Masc_domain.Start
              | Masc_domain.Done_action
              | Masc_domain.Cancel
              | Masc_domain.Release
              | Masc_domain.Approve_verification
              | Masc_domain.Reject_verification
              | Masc_domain.Submit_for_verification
              | Masc_domain.Submit_pr_evidence )
            , _
            , _
            , None ) -> Ok ()) [@warning "-4"]
        in
(* WORKAROUND: same justification as previous let*. *)
        let* () =
          (match action, task.task_status, prepare_verification_verdict with
          | ( Masc_domain.Approve_verification
            , Masc_domain.AwaitingVerification { verification_id; _ }
            , Some prepare ) ->
            (match
               prepare
                 ~task
                 ~verifier:agent_name
                 ~verification_id
                 ~decision:(`Approve notes)
             with
             | Ok () -> Ok ()
             | Error e ->
               Error
                 (Masc_domain.System
                    (Masc_domain.System_error.IoError
                       (Printf.sprintf
                          "verification verdict persistence failed before status \
                           transition (task=%s vrf=%s): %s"
                          task_id
                          verification_id
                          e))))
          | ( Masc_domain.Reject_verification
            , Masc_domain.AwaitingVerification { verification_id; _ }
            , Some prepare ) ->
            let reject_reason = if notes <> "" then notes else reason in
            (match
               prepare
                 ~task
                 ~verifier:agent_name
                 ~verification_id
                 ~decision:(`Reject reject_reason)
             with
             | Ok () -> Ok ()
             | Error e ->
               Error
                 (Masc_domain.System
                    (Masc_domain.System_error.IoError
                       (Printf.sprintf
                          "verification verdict persistence failed before status \
                           transition (task=%s vrf=%s): %s"
                          task_id
                          verification_id
                          e))))
          | ( (Masc_domain.Approve_verification | Masc_domain.Reject_verification)
            , _
            , Some _ ) ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "verification verdict action did not start from \
                        AwaitingVerification for task %s"
                       task_id)))
          | ( ( Masc_domain.Claim
              | Masc_domain.Start
              | Masc_domain.Done_action
              | Masc_domain.Cancel
              | Masc_domain.Release
              | Masc_domain.Submit_for_verification
              | Masc_domain.Submit_pr_evidence )
            , _
            , Some _ ) -> Ok ()
          | ( ( Masc_domain.Claim
              | Masc_domain.Start
              | Masc_domain.Done_action
              | Masc_domain.Cancel
              | Masc_domain.Release
              | Masc_domain.Submit_for_verification
              | Masc_domain.Submit_pr_evidence
              | Masc_domain.Approve_verification
              | Masc_domain.Reject_verification )
            , _
            , None ) -> Ok ()) [@warning "-4"]
        in
        (match decision.drift with
         | Some Coord_task_lifecycle.Claimed_to_done_skip ->
(* FSM drift: TLA+ KeeperTaskInterlock.DoneTask requires in_progress. *)
           (Atomic.get Coord_hooks.fsm_drift_observer_fn)
             ~variant:(drift_variant_label Coord_task_lifecycle.Claimed_to_done_skip)
             ~force
             ~agent_name;
           Log.RoomTask.warn
             "fsm_drift claimed_to_done_skip task=%s agent=%s force=%b"
             task_id
             agent_name
             force
         | None -> ());
(* #10449: Observe task completion path + contract presence so operators can split bypass-rate by cause (no contract vs. *)
        (match new_status with
         | Masc_domain.Done _ ->
           let contract_state = classify_contract_state task.contract in
           let path = classify_completion_path ~action ~drift:decision.drift ~force in
           (Atomic.get Coord_hooks.task_completion_path_observed_fn)
             ~path
             ~contract_state
             ~agent_name
         | Masc_domain.Todo
         | Masc_domain.Claimed _
         | Masc_domain.InProgress _
         | Masc_domain.AwaitingVerification _
         | Masc_domain.Cancelled _ -> ());
        (match action, task.task_status with
         | Masc_domain.Release, Masc_domain.Todo ->
(* Idempotent: already in backlog, nothing to release. *)
           Log.RoomTask.debug "release on already-todo task %s — no-op" task_id
         | Masc_domain.Claim, _
         | Masc_domain.Start, _
         | Masc_domain.Done_action, _
         | Masc_domain.Cancel, _
         | Masc_domain.Submit_for_verification, _
         | Masc_domain.Submit_pr_evidence, _
         | Masc_domain.Approve_verification, _
         | Masc_domain.Reject_verification, _
         | Masc_domain.Release, Masc_domain.Claimed _
         | Masc_domain.Release, Masc_domain.InProgress _
         | Masc_domain.Release, Masc_domain.AwaitingVerification _
         | Masc_domain.Release, Masc_domain.Done _
         | Masc_domain.Release, Masc_domain.Cancelled _ -> ());
(* #10719: surface tasks that have crossed oscillation thresholds so dashboards/triage can pick them up before they reach 20+ cycles with zero progress. *)
        (match action with
         | Masc_domain.Release ->
           let cc = task.cycle_count + 1 in
           let escalation =
             if task.cycle_count = 19
             then Some ("severe", 20)
             else if task.cycle_count = 9
             then Some ("major", 10)
             else if task.cycle_count = 4
             then Some ("threshold", 5)
             else None
           in
           (match escalation with
            | None -> ()
            | Some (level, threshold) ->
(* WARN line is the observability surface: structured [level=] label lets operators grep [task_oscillation_severe] to find the worst cases without scanning every release. *)
              Log.RoomTask.warn
                "task_oscillation_%s task=%s agent=%s cycle_count=%d threshold=%d \
                 (sustained claim->release loop, candidate for triage; consider \
                 reformulation or human escalation if level=severe)"
                level
                task_id
                agent_name
                cc
                threshold)
         | Masc_domain.Claim
         | Masc_domain.Start
         | Masc_domain.Done_action
         | Masc_domain.Cancel
         | Masc_domain.Submit_for_verification
         | Masc_domain.Submit_pr_evidence
         | Masc_domain.Approve_verification
         | Masc_domain.Reject_verification -> ());
        if new_status = task.task_status && set_current = None
        then
(* Idempotent no-op: status unchanged, skip write/events. Match None explicitly so set_current=Some is never silently dropped. *)
          Ok
            (Printf.sprintf
               "%s already %s (no-op)"
               task_id
               (task_status_to_string task.task_status))
        else (
          let backlog_update =
            Coord_task_transition_executor.build_backlog_update
              ~backlog
              ~task_id
              ~action
              ~new_status
              ~handoff_context
          in
          write_backlog config backlog_update.backlog;
          update_local_agent_state config ~agent_name (fun agent ->
            match set_current with
            | Some _ -> { agent with status = Busy; current_task = Some task_id }
            | None ->
              if agent.current_task = Some task_id
              then { agent with status = Active; current_task = None }
              else agent);
          log_event
            config
            (transition_log_event
               ~event_type:Task_transition
               ~agent_name
               ~task_id
               ~from_status:task.task_status
               ~to_status:new_status
               ~action:action_s
               ~forced:force
               ?notes:(trim_opt (Some notes))
               ?reason:(trim_opt (Some reason))
               ?handoff_context:backlog_update.persisted_handoff_context
               ());
          (match action with
           | Masc_domain.Claim ->
             emit_task_activity config ~agent_name ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Masc_domain.Start ->
             emit_task_activity config ~agent_name ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Started)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Masc_domain.Done_action ->
             emit_task_activity config ~agent_name ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Done)
               ~payload:(`Assoc [ "task_id", `String task_id; ("notes", if notes = "" then `Null else `String notes) ])
           | Masc_domain.Cancel ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Cancelled)
               ~payload:
                 (`Assoc
                     [ "task_id", `String task_id
                     ; ("reason", if reason = "" then `Null else `String reason)
                     ])
           | Masc_domain.Release ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Released)
               ~payload:
                 (`Assoc
                     ([ "task_id", `String task_id ]
                      @
                      match handoff_context with
                      | Some handoff_context ->
                        [ ( "handoff_context"
                          , Masc_domain.task_handoff_context_to_yojson handoff_context )
                        ]
                      | None -> []))
           | Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence ->
             let payload =
               `Assoc
                 ([ "task_id", `String task_id ]
                  @
                  match handoff_context with
                  | Some handoff_context ->
                    [ ( "handoff_context"
                      , Masc_domain.task_handoff_context_to_yojson handoff_context )
                    ]
                  | None -> [])
             in
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Submit_for_verification)
               ~payload
           | Masc_domain.Approve_verification ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Approved)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Masc_domain.Reject_verification ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Rejected)
               ~payload:(`Assoc [ "task_id", `String task_id ]));
          let duration_ms = match action with
            | Masc_domain.Done_action | Masc_domain.Cancel ->
              Some (max 0 (int_of_float ((now_ts -. task_started_at_unix task.task_status) *. 1000.0)))
            | Masc_domain.Claim
            | Masc_domain.Start
            | Masc_domain.Release
            | Masc_domain.Submit_for_verification
            | Masc_domain.Submit_pr_evidence
            | Masc_domain.Approve_verification
            | Masc_domain.Reject_verification -> None
          in
          observe_task_transition
            config
            ~agent_name
            ~task_id
            ~transition:action
            ~details:
              (task_transition_details
                 ~from_status:task.task_status
                 ~to_status:new_status
                 ?notes:(if notes = "" then None else Some notes)
                 ?reason:(if reason = "" then None else Some reason)
                 ?duration_ms
                 ~forced:force
                 ());
          (match action with
           | Masc_domain.Done_action ->
             Coord_task_cleanup.run_done_hooks config ~agent_name ~task_id ~force;
             Coord_task_cleanup.cleanup_worktree_for_transition config ~agent_name ~task_id task "task_done"
           | Masc_domain.Cancel ->
             Coord_task_cleanup.run_cancel_hooks config ~agent_name;
             Coord_task_cleanup.cleanup_worktree_for_transition config ~agent_name ~task_id task "task_cancel"
           | Masc_domain.Release ->
             Coord_task_cleanup.cleanup_worktree_for_transition config ~agent_name ~task_id task "task_release"
           | Masc_domain.Claim
           | Masc_domain.Start
           | Masc_domain.Submit_for_verification
           | Masc_domain.Submit_pr_evidence
           | Masc_domain.Approve_verification
           | Masc_domain.Reject_verification -> ());
          Ok
            (Printf.sprintf
               "%s %s → %s"
               task_id
               (task_status_to_string task.task_status)
               (task_status_to_string new_status)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e))))
  |> Coord_task_verification.flatten_lock_result
;;
