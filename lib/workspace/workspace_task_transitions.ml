(* * Workspace_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next. *)
open Masc_domain
include Workspace_utils
include Workspace_state
include Workspace_broadcast
open Workspace_backlog
(* Sub-module includes — re-export all bindings from extracted modules. *)
include Workspace_task_classify
include Workspace_task_create
include Workspace_task_claim
(* RFC-0088 §1 follow-up (#21065 review): typed surface for the idempotent
   no-op transition. Previously the only signal was the "(no-op)" substring in
   the [Ok msg] string, which callers had to sniff with substring matching. *)
type transition_outcome =
  { message : string
  ; noop : bool
  }

let transition_task_outcome_r
      config
      ~agent_name
      ~task_id
      ~action
      ?prepare_verification_request
      ?compensate_verification_request
      ?prepare_verification_verdict
      ?expected_version
      ?(notes = "")
      ?(reason = "")
      ?handoff_context
      ?(authority = Masc_domain.Assignee)
      ()
  : transition_outcome Masc_domain.masc_result
  =
  let open Result.Syntax in
  (* RFC-0262: project the typed authority back to the legacy [forced] bool for
     the drift / completion-path / audit-log / telemetry sinks, preserving their
     existing shape. Operator/System override ownership (the old force=true);
     Assignee does not. *)
  let forced =
    match (authority : Masc_domain.completion_authority) with
    | Assignee -> false
    | Operator | System -> true
  in
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
        (* RFC-0323 G-10: the typed reclaim claim precheck is retired — the
           FSM decision below owns claimability by status alone. The evidence
           requirements for submission/approval (#23719) stay. *)
        let* () =
          match action with
          | Masc_domain.Claim
          | Masc_domain.Start
          | Masc_domain.Cancel
          | Masc_domain.Release -> Ok ()
          | Masc_domain.Done_action
          | Masc_domain.Submit_for_verification ->
            (* #23719 evidence gate, scoped to the RFC-0323 Phase A predicate
               (contract.strict, same as the G-1 done guard). Unconditional
               enforcement regressed the G-2 deterministic probe and broke the
               invariant documented below (empty evidence is valid for
               analysis-only / advisory-contract tasks) — an unannounced
               Phase B, exactly what the G-1 predicate decision avoided.
               "Declared evidence" mirrors the verifier-request projection
               (contract refs + typed handoff refs, prose excluded): a
               contract that names its evidence up front satisfies the
               gate without re-supplying refs at submit time. *)
            if not (Masc_domain.task_requires_verification task)
            then Ok ()
            else if
              Workspace_task_verification.declared_verification_evidence_refs
                task handoff_context
              = []
            then
              Error
                (Masc_domain.Task
                   (Masc_domain.Task_error.InvalidState
                      "Strict-contract task completion requires declared evidence: contract required_evidence/verify_gate_evidence or handoff_context.evidence_refs (a verifier needs something to approve)"))
            else Ok ()
          | Masc_domain.Approve_verification
          | Masc_domain.Reject_verification ->
            if not (Masc_domain.task_requires_verification task)
            then Ok ()
            else if
              Workspace_task_verification.declared_verification_evidence_refs
                task None
              = []
            then
              Error
                (Masc_domain.Task
                   (Masc_domain.Task_error.InvalidState
                      "Approve/reject on a strict-contract task requires declared evidence: contract required_evidence/verify_gate_evidence or persisted handoff_context.evidence_refs"))
            else Ok ()
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
            | Masc_domain.Approve_verification
            | Masc_domain.Reject_verification ), _ -> Ok ())
          [@warning "-4"]
        in
        let now = now_iso () in
        let now_ts = Time_compat.now () in
        let action_s = Masc_domain.task_action_to_string action in
        let* decision =
          match
            Workspace_task_lifecycle.decide
              ~verification_enabled:(Env_config_runtime.Verification.fsm_enabled ())
              (* RFC-0323 G-5 Phase B: when [Verification.default_on] is set,
                 treat every task as verification-required so completion
                 routes through submit→approve. The evidence gate above
                 reads [task_requires_verification] (= contract.strict)
                 directly and is intentionally NOT flipped here — keeping
                 it on Phase-A scope avoids the #23719 G-2 regression
                 (unannounced Phase B). Default off (readiness gate §5). *)
              ~requires_verification:
                (Masc_domain.task_requires_verification task
                 || Env_config_runtime.Verification.default_on ())
              ~verification_timeout_seconds:
                (Env_config_runtime.Verification.timeout_deadline_seconds ())
              ~new_verification_id:(fun () -> Random_id.prefixed ~prefix:"vrf-" ~bytes:16)
              ~same_agent:(same_task_actor config agent_name)
              ~agent_name
              ~task_id
              ~task_status:task.task_status
              ~action
              ~now
              ~authority
              ~system_gate_exempt:false
              ~notes
              ~reason
          with
          | Ok decision -> Ok decision
          | Error Workspace_task_lifecycle.Self_approval ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Self-approval not allowed: verifier must be a different agent"))
          | Error Workspace_task_lifecycle.Self_rejection ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Self-rejection not allowed: verifier must be a different agent"))
          | Error Workspace_task_lifecycle.Verification_disabled ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Verification FSM not enabled (MASC_VERIFICATION_FSM_ENABLED=false)"))
          | Error Workspace_task_lifecycle.Verification_required_use_submit ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Task has a strict verification contract (contract.strict=true); use submit_for_verification — a verifier (not the assignee) then approves it to done (RFC-0323 G-1, implements RFC-0308)"))
          | Error Workspace_task_lifecycle.Invalid_transition ->
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
                 action=claim then action=start; complete via \
                 submit_for_verification → approve (action=done only for \
                 non-strict tasks)."
              | Masc_domain.Todo, Masc_domain.Start ->
                " Remediation: task is still in 'todo'. Call masc_transition \
                 action=claim first — start needs ownership."
              | Masc_domain.Claimed _, Masc_domain.Release when not own_assignee ->
                " Remediation: this task is claimed by another keeper. Use \
                 masc_board_post to ask that agent to release/hand off, or claim a \
                 different task with keeper_task_claim."
              | Masc_domain.Claimed _, Masc_domain.Done_action when not own_assignee ->
                " Remediation: only the current assignee can mark a task done. Pick a \
                 different task or align via masc_board_post."
              | (Masc_domain.Claimed _ | Masc_domain.InProgress _), Masc_domain.Cancel
                when not own_assignee ->
                " Remediation: cancellation requires owning the task. Use \
                 masc_board_post to ask the current assignee to cancel or release, or \
                 claim a different task with keeper_task_claim."
              | (Masc_domain.Claimed _ | Masc_domain.InProgress _), Masc_domain.Submit_for_verification
                when not own_assignee ->
                " Remediation: submit_for_verification requires owning the task. Use \
                 masc_board_post to ask the current assignee to release, or claim a \
                 different task with keeper_task_claim."
              | Masc_domain.InProgress _, Masc_domain.Claim ->
                " Remediation: task is already in_progress under someone. Use \
                 keeper_task_claim for unclaimed work."
              | Masc_domain.InProgress _, Masc_domain.Start ->
                " Remediation: task is already in_progress. Valid actions from \
                 in_progress: submit_for_verification (→ verifier approve), done \
                 (non-strict tasks only), release, cancel."
              | Masc_domain.Done _, _ ->
                " Remediation: task is already in a terminal state (done). To \
                 re-run this work, create a new task with predecessor_task_id \
                 via masc_add_task (RFC-0323); use masc_tasks to find claimable \
                 items."
              | Masc_domain.Cancelled _, _
              | Masc_domain.OperatorBlocked _, _ ->
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
        let new_status = decision.Workspace_task_lifecycle.new_status in
        let set_current = decision.set_current in
        let* () =
          match action with
          | Masc_domain.Submit_for_verification
            when String.length (String.trim notes) = 0 ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "submit_for_verification requires non-empty notes describing the \
                     deliverable and evidence references"))
          | Masc_domain.Claim
          | Masc_domain.Start
          | Masc_domain.Done_action
          | Masc_domain.Cancel
          | Masc_domain.Release
          | Masc_domain.Submit_for_verification
          | Masc_domain.Approve_verification
          | Masc_domain.Reject_verification -> Ok ()
        in
        (* WORKAROUND: action (9) × task_status (6) × new_status (6) × option (2) = 648 combos. *)
        let* () =
          (match action, task.task_status, new_status, prepare_verification_request with
          | ( Masc_domain.Submit_for_verification
            , _
            , Masc_domain.AwaitingVerification { assignee; verification_id; _ }
            , prepare_opt ) ->
            (* RFC-0109 Phase E: gating is owned by Task_completion_gate (called
               from tool_task.ml before transition_task_r). Here we only
               collect typed evidence refs as observability metadata for
               the verifier request output. Empty list is valid for
               analysis-only / no-contract tasks — Phase D's decision
               matrix row 5 already passed them. *)
            let evidence_refs =
              Workspace_task_verification.verification_submission_evidence_refs task ~notes handoff_context
            in
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
          | ( Masc_domain.Submit_for_verification
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
              | Masc_domain.Submit_for_verification )
            , _
            , _
            , None ) -> Ok ()) [@warning "-4"]
        in
(* RFC-0221 §3.2: the approve/reject verdict record write is NOT gated here
   anymore. [task_status] is the sole outcome authority (approve → Done with
   the verdict in [notes]; reject → InProgress with the reason delivered via
   the separate post-commit notify), so the record is audit, not content, and
   it is written best-effort AFTER [write_backlog] commits — see below. The
   old pre-write gate made an audit-write failure block a decided outcome and
   re-admitted the drift (record Completed, task AwaitingVerification). *)
        (match decision.drift with
         | Some Workspace_task_lifecycle.Claimed_to_done_skip ->
(* FSM drift: TLA+ KeeperTaskInterlock.DoneTask requires in_progress. *)
           (Atomic.get Workspace_hooks.fsm_drift_observer_fn)
             ~variant:(drift_variant_label Workspace_task_lifecycle.Claimed_to_done_skip)
             ~force:forced
             ~agent_name;
           Log.TaskState.warn
             "fsm_drift claimed_to_done_skip task=%s agent=%s force=%b"
             task_id
             agent_name
             forced
         | None -> ());
(* #10449: Observe task completion path + contract presence so operators can split bypass-rate by cause (no contract vs. *)
        (match new_status with
         | Masc_domain.Done _ ->
           let contract_state = classify_contract_state task.contract in
           let path = classify_completion_path ~action ~drift:decision.drift ~force:forced in
           (Atomic.get Workspace_hooks.task_completion_path_observed_fn)
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
           Log.TaskState.debug "release on already-todo task %s — no-op" task_id
        | Masc_domain.Claim, _
        | Masc_domain.Start, _
        | Masc_domain.Done_action, _
        | Masc_domain.Cancel, _
        | Masc_domain.Submit_for_verification, _
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
              Log.TaskState.warn
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
         | Masc_domain.Approve_verification
         | Masc_domain.Reject_verification -> ());
        if new_status = task.task_status && set_current = None
        then
(* Idempotent no-op: status unchanged, skip write/events. Match None explicitly so set_current=Some is never silently dropped. *)
          Ok
            { message =
                Printf.sprintf
                  "%s already %s (no-op)"
                  task_id
                  (task_status_to_string task.task_status)
            ; noop = true
            }
        else (
          let backlog_update =
            Workspace_task_transition_executor.build_backlog_update
              ~backlog
              ~task_id
              ~action
              ~new_status
              ~handoff_context
          in
          (* RFC-0221 §3.1: [write_backlog] is the atomic commit point for the
             task outcome. Submit writes the verification record before this
             commit (content the verifier reads); if the commit fails after the
             record was written, compensate by deleting the record so the record
             store and [task_status] are never left disagreeing, then surface
             the failure. Submit is the only action that writes a record before
             this point, so the match scopes compensation to it. Cancellation is
             re-raised without compensating — the orphan is inert (its task is
             not [AwaitingVerification]) and reaped later, and running store I/O
             inside a cancelled fiber is unsafe. *)
          (try write_backlog config backlog_update.backlog with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             (match compensate_verification_request with
              | None -> ()
              | Some compensate ->
                (match action with
                 | Masc_domain.Submit_for_verification ->
                   (match new_status with
                    | Masc_domain.AwaitingVerification { verification_id; _ } ->
                      compensate ~verification_id
                    | Masc_domain.Todo
                    | Masc_domain.Claimed _
                    | Masc_domain.InProgress _
                    | Masc_domain.Done _
                    | Masc_domain.Cancelled _ -> ())
                 | Masc_domain.Claim
                 | Masc_domain.Start
                 | Masc_domain.Done_action
                 | Masc_domain.Cancel
                 | Masc_domain.Release
                 | Masc_domain.Approve_verification
                 | Masc_domain.Reject_verification -> ()));
             raise exn);
          (* RFC-0221 §3.3: clear stale agent task-cache entries AFTER the
             commit so agents that cache the task don't emit stale broadcasts
             referencing the old status. *)
          Task_cache_invariant.clear_stale_agent_task config
            ~agent_name ~task_id ~status:new_status
            ~module_name:"transition_task_r";
          (* RFC-0221 §3.2: write the verdict audit record best-effort AFTER the
             commit. The outcome already lives in [task_status] (approve → Done
             carrying the verdict in [notes]; reject → InProgress, its reason
             delivered by the separate post-commit notify), so a record-write
             failure is logged, not surfaced — it can neither block nor
             contradict the committed outcome. A failure leaves an inert orphan
             (record non-terminal, task terminal / in-progress) reaped per §3.4;
             no behavior-driving consumer acts on it (§3.5 consumer audit).
             [prepare] returns a result on I/O error; a cancellation raises and
             propagates to the outer handler. Nested exhaustive match (no
             catch-all) so a new action / status forces review. *)
          (match prepare_verification_verdict with
           | None -> ()
           | Some prepare ->
             (match action with
              | Masc_domain.Approve_verification ->
                (match task.task_status with
                 | Masc_domain.AwaitingVerification { verification_id; _ } ->
                   (match
                      prepare ~task ~verifier:agent_name ~verification_id
                        ~decision:(`Approve notes)
                    with
                    | Ok () -> ()
                    | Error e ->
                      Log.TaskState.warn
                        "[RFC-0221] verdict audit write failed post-commit \
                         (task=%s vrf=%s decision=approve): %s — outcome stands, \
                         record left inert"
                        task_id
                        verification_id
                        e)
                 | Masc_domain.Todo
                 | Masc_domain.Claimed _
                 | Masc_domain.InProgress _
                 | Masc_domain.Done _
                 | Masc_domain.Cancelled _ -> ())
              | Masc_domain.Reject_verification ->
                (match task.task_status with
                 | Masc_domain.AwaitingVerification { verification_id; _ } ->
                   let reject_reason = if notes <> "" then notes else reason in
                   (match
                      prepare ~task ~verifier:agent_name ~verification_id
                        ~decision:(`Reject reject_reason)
                    with
                    | Ok () -> ()
                    | Error e ->
                      Log.TaskState.warn
                        "[RFC-0221] verdict audit write failed post-commit \
                         (task=%s vrf=%s decision=reject): %s — outcome stands, \
                         record left inert"
                        task_id
                        verification_id
                        e)
                 | Masc_domain.Todo
                 | Masc_domain.Claimed _
                 | Masc_domain.InProgress _
                 | Masc_domain.Done _
                 | Masc_domain.Cancelled _ -> ())
              | Masc_domain.Claim
              | Masc_domain.Start
              | Masc_domain.Done_action
              | Masc_domain.Cancel
              | Masc_domain.Release
              | Masc_domain.Submit_for_verification -> ()));
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
               ~forced:forced
               ~authority
               ?assignee:(Masc_domain.task_assignee_of_status task.task_status)
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
           | Masc_domain.Submit_for_verification ->
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
             (* RFC-0323 G-3: the event actor is the verifier; carry the
                assignee so graph reducers can close the assignee's
                works_on edge. *)
             let payload =
               match new_status with
               | Masc_domain.Done { assignee; _ } ->
                 `Assoc
                   [ "task_id", `String task_id; "assignee", `String assignee ]
               | Masc_domain.Todo
               | Masc_domain.Claimed _
               | Masc_domain.InProgress _
               | Masc_domain.AwaitingVerification _
               | Masc_domain.Cancelled _ -> `Assoc [ "task_id", `String task_id ]
             in
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Approved)
               ~payload
           | Masc_domain.Reject_verification ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Rejected)
               ~payload:(`Assoc [ "task_id", `String task_id ]));
          (* RFC-0323 G-3: completion side effects key off the RESULT (Done),
             not the action — otherwise Approve_verification completions
             record no duration. The value measures the last status phase
             (started_at for in_progress, submitted_at for
             awaiting_verification). *)
          let completes_task =
            Masc_domain.task_status_is_done new_status
            && not (Masc_domain.task_status_is_done task.task_status)
          in
          let phase_duration_ms () =
            Some
              (max 0 (int_of_float ((now_ts -. task_started_at_unix task.task_status) *. 1000.0)))
          in
          let duration_ms =
            if completes_task
            then phase_duration_ms ()
            else (
              match action with
              | Masc_domain.Cancel -> phase_duration_ms ()
              | Masc_domain.Done_action
              | Masc_domain.Claim
              | Masc_domain.Start
              | Masc_domain.Release
              | Masc_domain.Submit_for_verification
              | Masc_domain.Approve_verification
              | Masc_domain.Reject_verification -> None)
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
                 ~forced:forced
                 ());
          (* RFC-0323 G-3: done hooks (economy earn, relation/hebbian) fire for
             every transition that PRODUCES Done — Done via
             Approve_verification included. The completer is the Done record's
             assignee: on approve the acting [agent_name] is the verifier. *)
          (match new_status with
           | Masc_domain.Done { assignee; _ } ->
             if completes_task
             then
               Workspace_task_cleanup.run_done_hooks
                 config
                 ~agent_name:assignee
                 ~task_id
           | Masc_domain.Todo
           | Masc_domain.Claimed _
           | Masc_domain.InProgress _
           | Masc_domain.AwaitingVerification _
           | Masc_domain.Cancelled _ -> ());
          (match action with
           | Masc_domain.Cancel ->
             Workspace_task_cleanup.run_cancel_hooks config ~agent_name
           | Masc_domain.Done_action
           | Masc_domain.Release
           | Masc_domain.Claim
           | Masc_domain.Start
           | Masc_domain.Submit_for_verification
           | Masc_domain.Approve_verification
           | Masc_domain.Reject_verification -> ());
          Ok
            { message =
                Printf.sprintf
                  "%s %s → %s"
                  task_id
                  (task_status_to_string task.task_status)
                  (task_status_to_string new_status)
            ; noop = false
            })
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e))))
  |> Workspace_task_verification.flatten_lock_result
;;

let transition_task_r
      config
      ~agent_name
      ~task_id
      ~action
      ?prepare_verification_request
      ?compensate_verification_request
      ?prepare_verification_verdict
      ?expected_version
      ?notes
      ?reason
      ?handoff_context
      ?authority
      ()
  : string Masc_domain.masc_result
  =
  transition_task_outcome_r
    config
    ~agent_name
    ~task_id
    ~action
    ?prepare_verification_request
    ?compensate_verification_request
    ?prepare_verification_verdict
    ?expected_version
    ?notes
    ?reason
    ?handoff_context
    ?authority
    ()
  |> Result.map (fun outcome -> outcome.message)
;;
