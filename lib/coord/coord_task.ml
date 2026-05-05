(** Coord_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next.

    Facade module: includes Coord_task_classify, Coord_task_create, and
    Coord_task_claim sub-modules, then defines the remaining mega-functions
    ([transition_task_r], [cancel_task_r], [link_task_execution_artifacts_r])
    that depend on bindings from all three.  All bindings are part of the
    public [Coord] interface via [include Coord_task] in [lib/coord.ml]. *)

open Masc_domain
include Coord_utils
include Coord_state
include Coord_broadcast

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
  let* () = if not (is_initialized config) then Error (Masc_domain.System Masc_domain.System_error.NotInitialized) else Ok () in
  let* () =
    match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ -> Ok ()
  in
  (* BUG-006: Resolve agent name to canonical form (e.g. "keeper-coder" ->
     "keeper-coder-agent") so the assignee guard matches the name recorded
     at claim time.  Only the exact [-agent] suffix form is accepted;
     broader prefix matches from [resolve_agent_name] are discarded to
     prevent ambiguous identity mapping across keeper agent files. *)
  let agent_name = resolve_agent_name_strict config agent_name in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      match read_backlog_r config with
      | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
      | Ok backlog ->
        let* () =
          match expected_version with
          | Some v when backlog.version <> v ->
            Error
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
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
          | Masc_domain.Cancel ->
            Ok ()
        in
        let* () =
          match action, do_not_reclaim_reason_blocks_claim task.do_not_reclaim_reason with
          | Masc_domain.Claim, Some r ->
            Error
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                 (Printf.sprintf "Task %s is blocked from re-claim: %s" task_id r)))
          | _ -> Ok ()
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
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                 "Self-approval not allowed: verifier must be a different agent"))
          | Error Coord_task_lifecycle.Self_rejection ->
            Error
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                 "Self-rejection not allowed: verifier must be a different agent"))
          | Error Coord_task_lifecycle.Verification_disabled ->
            Error
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                 "Verification FSM not enabled (MASC_VERIFICATION_FSM_ENABLED=false)"))
          | Error Coord_task_lifecycle.Invalid_transition ->
            let assignee_hint =
              match task_assignee_of_status task.task_status with
              | Some a when a <> agent_name -> Printf.sprintf ", current_assignee=%s" a
              | _ -> ""
            in
            (* Issue #7646: ownership-mismatch dominates; only show
               valid_next_actions when the failure isn't an ownership
               problem. Otherwise the hint risks misdirecting the LLM
               toward retrying actions it cannot perform on someone
               else's task. *)
            let actions_hint =
              if assignee_hint <> "" then "" else next_actions_hint task.task_status
            in
            (* Concrete remediation. Field evidence 2026-04-17/18 showed
               ~30 [todo -> release] rejections — keepers called release
               on tasks they never claimed, got a terse FSM error, and
               retried with the same action rather than claiming first.
               Name the exact next call to make so small-LLM keepers can
               recover on the next turn. *)
            let remediation =
              let own_assignee =
                match task_assignee_of_status task.task_status with
                | Some a when a = agent_name -> true
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
              | (Masc_domain.Claimed _ | Masc_domain.InProgress _), Masc_domain.Cancel when not own_assignee
                ->
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
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
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
        let* () =
          match action, task.task_status, new_status, prepare_verification_request with
          | ( (Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence),
              _,
              Masc_domain.AwaitingVerification { assignee; verification_id; _ },
              Some prepare ) ->
            let evidence_refs =
              match task.contract with
              | Some c -> c.verify_gate_evidence
              | None -> []
            in
            (match prepare ~task ~assignee ~verification_id ~evidence_refs with
             | Ok () -> Ok ()
             | Error e ->
               Error
                 (Masc_domain.System (Masc_domain.System_error.IoError
                    (Printf.sprintf
                       "verification request creation failed before status transition \
                        (task=%s vrf=%s): %s"
                       task_id
                       verification_id
                       e))))
          | (Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence), _, _, Some _ ->
            Error
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                 (Printf.sprintf
                    "submit_for_verification did not produce AwaitingVerification \
                     for task %s"
                    task_id)))
          | ( Masc_domain.Claim
            | Masc_domain.Start
            | Masc_domain.Done_action
            | Masc_domain.Cancel
            | Masc_domain.Release
            | Masc_domain.Approve_verification
            | Masc_domain.Reject_verification ),
            _,
            _,
            Some _ ->
            Ok ()
          | ( Masc_domain.Claim
            | Masc_domain.Start
            | Masc_domain.Done_action
            | Masc_domain.Cancel
            | Masc_domain.Release
            | Masc_domain.Approve_verification
            | Masc_domain.Reject_verification
            | Masc_domain.Submit_for_verification
            | Masc_domain.Submit_pr_evidence ),
            _,
            _,
            None ->
            Ok ()
        in
        let* () =
          match action, task.task_status, prepare_verification_verdict with
          | ( Masc_domain.Approve_verification,
              Masc_domain.AwaitingVerification { verification_id; _ },
              Some prepare ) ->
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
                 (Masc_domain.System (Masc_domain.System_error.IoError
                    (Printf.sprintf
                       "verification verdict persistence failed before status transition \
                        (task=%s vrf=%s): %s"
                       task_id
                       verification_id
                       e))))
          | ( Masc_domain.Reject_verification,
              Masc_domain.AwaitingVerification { verification_id; _ },
              Some prepare ) ->
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
                 (Masc_domain.System (Masc_domain.System_error.IoError
                    (Printf.sprintf
                       "verification verdict persistence failed before status transition \
                        (task=%s vrf=%s): %s"
                       task_id
                       verification_id
                       e))))
          | (Masc_domain.Approve_verification | Masc_domain.Reject_verification), _, Some _ ->
            Error
              (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                 (Printf.sprintf
                    "verification verdict action did not start from AwaitingVerification \
                     for task %s"
                    task_id)))
          | ( Masc_domain.Claim
            | Masc_domain.Start
            | Masc_domain.Done_action
            | Masc_domain.Cancel
            | Masc_domain.Release
            | Masc_domain.Submit_for_verification
            | Masc_domain.Submit_pr_evidence ),
            _,
            Some _ ->
            Ok ()
          | ( Masc_domain.Claim
            | Masc_domain.Start
            | Masc_domain.Done_action
            | Masc_domain.Cancel
            | Masc_domain.Release
            | Masc_domain.Submit_for_verification
            | Masc_domain.Submit_pr_evidence
            | Masc_domain.Approve_verification
            | Masc_domain.Reject_verification ),
            _,
            None ->
            Ok ()
        in
        (match decision.drift with
         | Some Coord_task_lifecycle.Claimed_to_done_skip ->
           (* FSM drift: TLA+ KeeperTaskInterlock.DoneTask requires in_progress.
              Log WARN so dashboards can surface keepers that skip Start. The
              jump is still permitted for client compatibility; strictness
              ratchet follows once keeper_task_start is exposed.

              #9795: also tick the [fsm_drift_observer_fn] hook so
              ratchet readiness ("is the skip pattern rare enough
              to promote to a hard error?") has a measurable
              baseline instead of relying on log-scraping. Hook is
              wired by [lib/coord.ml] at startup to emit a
              Prometheus counter. *)
           (Atomic.get Coord_hooks.fsm_drift_observer_fn)
             ~variant:(drift_variant_label
                         Coord_task_lifecycle.Claimed_to_done_skip)
             ~force
             ~agent_name;
           Log.RoomTask.warn
             "fsm_drift claimed_to_done_skip task=%s agent=%s force=%b"
             task_id
             agent_name
             force
         | None -> ());
        (* #10449: Observe task completion path + contract presence so
           operators can split bypass-rate by cause (no contract vs.
           gate mis-fire). Fires once per successful transition into
           [Done]; emit goes through [task_completion_path_observed_fn]
           so [masc_coord] keeps no direct [Prometheus] dep. *)
        (match new_status with
         | Masc_domain.Done _ ->
           let contract_state = classify_contract_state task.contract in
           let path =
             classify_completion_path ~action ~drift:decision.drift ~force
           in
           (Atomic.get Coord_hooks.task_completion_path_observed_fn)
             ~path ~contract_state ~agent_name
         | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
         | Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _ -> ());
        (match action, task.task_status with
         | Masc_domain.Release, Masc_domain.Todo ->
           (* Idempotent: already in backlog, nothing to release.
              Logged at debug so that callers passing a wrong task_id
              (e.g. confused the target of a multi-task release) can
              still detect the no-op without seeing it as an error. *)
           Log.RoomTask.debug "release on already-todo task %s — no-op" task_id
       | Masc_domain.Claim, _ | Masc_domain.Start, _ | Masc_domain.Done_action, _ | Masc_domain.Cancel, _
       | Masc_domain.Submit_for_verification, _ | Masc_domain.Submit_pr_evidence, _
       | Masc_domain.Approve_verification, _
       | Masc_domain.Reject_verification, _
       | Masc_domain.Release, Masc_domain.Claimed _ | Masc_domain.Release, Masc_domain.InProgress _
       | Masc_domain.Release, Masc_domain.AwaitingVerification _ | Masc_domain.Release, Masc_domain.Done _
       | Masc_domain.Release, Masc_domain.Cancelled _ -> ());
        (* #10719: surface tasks that have crossed oscillation thresholds
           so dashboards/triage can pick them up before they reach 20+
           cycles with zero progress.  Production observation
           (2026-04-26 backlog scan): task-049 hit cycle 20 still in
           [todo] — the previous single threshold at 5 fires once and
           then stays silent through the rest of the death-loop.

           Add additional crossings at 10 and 20 plus a Prometheus
           counter so each oscillation event is countable in PromQL.
           Fires only on the exact cycle_count transition (4->5, 9->10,
           19->20) to avoid log amplification on every subsequent
           release of the same task.  Pure observation: does not block
           the release. *)
        (match action with
         | Masc_domain.Release ->
           let cc = task.cycle_count + 1 in
           let escalation =
             if task.cycle_count = 19 then Some ("severe", 20)
             else if task.cycle_count = 9 then Some ("major", 10)
             else if task.cycle_count = 4 then Some ("threshold", 5)
             else None
           in
           (match escalation with
            | None -> ()
            | Some (level, threshold) ->
              (* WARN line is the observability surface: structured
                 [level=] label lets operators grep [task_oscillation_severe]
                 to find the worst cases without scanning every release.
                 We avoid Prometheus here because [masc_coord] doesn't
                 depend on the Prometheus module (and adding it would
                 create a circular dep with [masc_mcp]); future metric
                 wiring belongs in a callback pattern like
                 [Coord_hooks]. *)
              Log.RoomTask.warn
                "task_oscillation_%s task=%s agent=%s cycle_count=%d \
                 threshold=%d (sustained claim->release loop, candidate \
                 for triage; consider reformulation or human escalation \
                 if level=severe)"
                level task_id agent_name cc threshold)
         | Masc_domain.Claim | Masc_domain.Start
         | Masc_domain.Done_action | Masc_domain.Cancel
         | Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence
         | Masc_domain.Approve_verification
         | Masc_domain.Reject_verification -> ());
      if new_status = task.task_status && set_current = None then
        (* Idempotent no-op: status unchanged, skip write/events.
           Match None explicitly so set_current=Some is never silently dropped. *)
          Ok
            (Printf.sprintf
               "%s already %s (no-op)"
               task_id
               (task_status_to_string task.task_status))
        else (
          let new_tasks =
            List.map
              (fun (t : task) ->
                 if t.id = task_id
                 then (
                   let t =
                     match action with
                     | Masc_domain.Claim -> clear_soft_do_not_reclaim_reason t
                     | Masc_domain.Release
                     | Masc_domain.Start
                     | Masc_domain.Done_action
                     | Masc_domain.Cancel
                     | Masc_domain.Submit_for_verification
                     | Masc_domain.Submit_pr_evidence
                     | Masc_domain.Approve_verification
                     | Masc_domain.Reject_verification -> t
                   in
                   let cycle_count, do_not_reclaim_reason =
                     match action with
                     | Masc_domain.Release ->
                       ( t.cycle_count + 1
                       , derive_release_do_not_reclaim_reason t handoff_context )
                     | Masc_domain.Claim
                     | Masc_domain.Start
                     | Masc_domain.Done_action
                     | Masc_domain.Cancel
                     | Masc_domain.Submit_for_verification
                     | Masc_domain.Submit_pr_evidence
                     | Masc_domain.Approve_verification
                     | Masc_domain.Reject_verification -> t.cycle_count, t.do_not_reclaim_reason
                   in
                   { t with
                     task_status = new_status
                   ; handoff_context =
                       (match action with
                        | Masc_domain.Release -> handoff_context
                        | Masc_domain.Claim
                        | Masc_domain.Start
                        | Masc_domain.Done_action
                        | Masc_domain.Cancel
                        | Masc_domain.Submit_for_verification
                        | Masc_domain.Submit_pr_evidence
                        | Masc_domain.Approve_verification
                        | Masc_domain.Reject_verification -> None)
                   ; cycle_count
                   ; do_not_reclaim_reason
                   })
                 else t)
              backlog.tasks
          in
          let new_backlog =
            { tasks = new_tasks
            ; last_updated = now_iso ()
            ; version = backlog.version + 1
            }
          in
          write_backlog config new_backlog;
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
                  ?handoff_context:
                    (match handoff_context with
                     | Some _ when action = Masc_domain.Release -> handoff_context
                     | _ -> None)
                  ());
          (match action with
           | Masc_domain.Claim ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Masc_domain.Start ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Started)
               ~payload:(`Assoc [ "task_id", `String task_id ])
           | Masc_domain.Done_action ->
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Done)
               ~payload:
                 (`Assoc
                     [ "task_id", `String task_id
                     ; ("notes", if notes = "" then `Null else `String notes)
                     ])
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
             emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Submit_for_verification)
               ~payload:(`Assoc [ "task_id", `String task_id ])
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
          let duration_ms =
            match action with
            | Masc_domain.Done_action | Masc_domain.Cancel ->
              Some
                (max
                   0
                   (int_of_float
                      ((now_ts -. task_started_at_unix task.task_status) *. 1000.0)))
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
          (* #10899 follow-up — extract worktree auto-cleanup so it can
             fire on every terminal/handoff transition that orphans the
             current keeper's worktree, not just [Done_action].  Without
             this, [Cancel] / [Release] both leave [.masc/playground/
             <keeper>/repos/.../.worktrees/<task>/] behind: [Cancel] kills
             the task entirely (no future claimant), [Release] returns the
             task to claimable for a *different* keeper that creates its
             own worktree, leaving the original orphaned.  Best-effort
             matches the existing Done branch: filesystem GC must not
             fail the state transition. *)
          let cleanup_worktree_for_transition reason_label =
            match task.worktree with
            | None -> ()
            | Some _ ->
              (try
                 match
                   Coord_worktree.worktree_remove_r config ~agent_name ~task_id
                 with
                 | Ok msg ->
                   Log.RoomTask.info
                     "%s worktree auto-cleanup: %s" reason_label msg
                 | Error (System (System_error.IoError msg))
                   when (let lc = String.lowercase_ascii msg in
                         String.length lc >= 9
                         && (let sub = String.sub lc 0 9 in
                             sub = "worktree ")) ->
                   (* P2-1: "Worktree … not found" means the task had a
                      worktree record (worktree = Some _) but the directory
                      was never physically created on this host — typical for
                      Docker-isolated keepers whose sandbox lives inside the
                      container.  This is expected; demote to INFO so routine
                      best-effort cleanup no longer fires false-alarm WARNs. *)
                   Log.RoomTask.info
                     "%s worktree auto-cleanup: %s (worktree absent, skipped)"
                     reason_label msg
                 | Error e ->
                   Log.RoomTask.warn
                     "%s worktree auto-cleanup failed \
                      (best-effort, suppressed): %s"
                     reason_label (Masc_domain.masc_error_to_string e)
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 Log.RoomTask.warn
                   "%s worktree auto-cleanup raised \
                    (best-effort, suppressed): %s"
                   reason_label (Printexc.to_string exn))
          in
          (match action with
           | Masc_domain.Done_action ->
             (* Completion rewards are tied to the real state-changing done path;
                idempotent done no-ops return before this block. *)
             (try
                (Atomic.get Coord_hooks.agent_economy_earn_fn)
                  ~base_path:config.base_path
                  ~agent_name
                  ~reason:(Printf.sprintf "completed %s" task_id)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.RoomTask.error
                  "transition economy done hook: %s"
                  (Printexc.to_string exn));
             (try
                let active = (Coord_state.read_state config).active_agents in
                (Atomic.get Coord_hooks.relation_on_task_done_fn)
                  ~assignee:agent_name
                  ~active_agents:active;
                (* Hebbian: strengthen only against agents with active tasks,
                 not the full room. See working_agents doc for rationale. *)
                let workers = working_agents config in
                (Atomic.get Coord_hooks.hebbian_on_task_done_fn)
                  config
                  ~assignee:agent_name
                  ~active_agents:workers
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.RoomTask.error
                  "transition relation/hebbian done hook: %s"
                  (Printexc.to_string exn));
             (* #10899: auto-cleanup playground worktree on task done.
                Keepers used to be expected to call
                [masc_worktree_remove] themselves at task completion,
                but that is a fragile contract — keeper crashes,
                watchdog termination, and forgetfulness all leave
                worktree directories behind. Field log: 5d / 7
                keepers / ~3.4GB stale worktrees in
                [.masc/playground/<keeper>/repos/.../.worktrees/].

                Best-effort: if cleanup fails (uncommitted changes,
                race with another fiber, missing worktree dir), log
                a warn and continue. The state-change is the
                canonical lifecycle event; filesystem GC must not
                fail the task transition. *)
             cleanup_worktree_for_transition "task_done"
           | Masc_domain.Cancel ->
             (try
                let workers = working_agents config in
                (Atomic.get Coord_hooks.hebbian_on_task_cancelled_fn)
                  config
                  ~agent_name
                  ~active_agents:workers
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.RoomTask.error
                  "transition hebbian cancel hook: %s"
                  (Printexc.to_string exn));
             (* Cancel is terminal: no future claimant will pick up the
                worktree, so cleanup unconditionally. *)
             cleanup_worktree_for_transition "task_cancel"
           | Masc_domain.Release ->
             (* Release returns the task to claimable.  The releasing
                keeper's worktree is orphaned because the next claimant
                (potentially a different keeper) will create its own
                via [claim_post_provision_fn].  Cleanup the previous
                keeper's worktree to prevent the leak observed in
                #10899 (5d / 7 keepers / 3.4 GB). *)
             cleanup_worktree_for_transition "task_release"
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
    | e -> Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e))))
;;

(** Release task back to backlog - transition wrapper *)
let release_task_r config ~agent_name ~task_id ?expected_version ?handoff_context ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Release
    ?expected_version
    ?handoff_context
    ()
;;

(** Force-release a task regardless of assignee. Keeper privilege. *)
let force_release_task_r config ~agent_name ~task_id ?handoff_context ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Release
    ?handoff_context
    ~force:true
    ()
;;

(** Force-done a task regardless of assignee. Keeper privilege. *)
let force_done_task_r config ~agent_name ~task_id ~notes () : string Masc_domain.masc_result =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Done_action
    ~notes
    ~force:true
    ()
;;

(** Force-cancel a task regardless of assignee. System privilege.
    Used by [Verification_protocol.check_timeouts] to expire
    [AwaitingVerification] tasks whose verifier deadline has passed,
    so the FSM does not stall and re-emit Timeout posts forever. *)
let force_cancel_task_r config ~agent_name ~task_id ~reason ()
  : string Masc_domain.masc_result =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Cancel
    ~reason
    ~force:true
    ()
;;

(** Cancel a task - A2A compatible *)
let cancel_task_r config ~agent_name ~task_id ~reason : string Masc_domain.masc_result =
  if not (is_initialized config)
  then Error (Masc_domain.System Masc_domain.System_error.NotInitialized)
  else (
    let agent_name = resolve_agent_name_strict config agent_name in
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      try
        match read_backlog_r config with
        | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
        | Ok backlog ->
          let task_opt = List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks in
          (match task_opt with
           | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
           | Some task ->
             (* Can cancel if: Todo, Claimed by me, or InProgress by me *)
             let can_cancel =
               match task.task_status with
               | Masc_domain.Todo -> true
               | Masc_domain.Claimed { assignee; _ }
               | Masc_domain.InProgress { assignee; _ }
               | Masc_domain.AwaitingVerification { assignee; _ } -> assignee = agent_name
               | Masc_domain.Done _ | Masc_domain.Cancelled _ -> false
             in
             if not can_cancel
             then
               Error
                 (Masc_domain.Task (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "Cannot cancel task %s (already done/cancelled or owned by \
                        another agent)"
                       task_id)))
             else (
               let new_tasks =
                 List.map
                   (fun (t : task) ->
                      if t.id = task_id
                      then (
                        let new_cycle = t.cycle_count + 1 in
                        (* Set do_not_reclaim_reason only when the operator flags
                     an explicit hard stop in the cancel reason. *)
                        let auto_dnr =
                          match t.do_not_reclaim_reason with
                          | Some _ as existing ->
                            do_not_reclaim_reason_blocks_claim existing
                          | None ->
                            let lower = String.lowercase_ascii reason in
                            let flagged =
                              String_util.contains_substring lower "do not reclaim"
                              || String_util.contains_substring lower "scope mismatch"
                            in
                            if flagged && reason <> ""
                            then Some reason
                            else None
                        in
                        { t with
                          task_status =
                            Masc_domain.Cancelled
                              { cancelled_by = agent_name
                              ; cancelled_at = now_iso ()
                              ; reason = (if reason = "" then None else Some reason)
                              }
                        ; cycle_count = new_cycle
                        ; do_not_reclaim_reason = auto_dnr
                        })
                      else t)
                   backlog.tasks
               in
               let new_backlog =
                 { tasks = new_tasks
                 ; last_updated = now_iso ()
                 ; version = backlog.version + 1
                 }
               in
               write_backlog config new_backlog;
               (* Update agent status if they had this task *)
               update_local_agent_state config ~agent_name (fun agent ->
                 if agent.current_task = Some task_id
                 then { agent with status = Active; current_task = None }
                 else agent);
               let msg =
                 if reason = ""
                 then Printf.sprintf "Cancelled %s" task_id
                 else Printf.sprintf "Cancelled %s - %s" task_id reason
               in
               let _ = broadcast config ~from_agent:agent_name ~content:msg in
               emit_task_activity
                 config
                 ~agent_name
                 ~task_id
                 ~kind:(Event_kind.Task.to_string Event_kind.Task.Cancelled)
                 ~payload:
                   (`Assoc
                       [ "task_id", `String task_id
                       ; ("reason", if reason = "" then `Null else `String reason)
                       ]);
               log_event
                 config
                 (transition_log_event
                       ~event_type:Task_cancelled
                       ~agent_name
                       ~task_id
                       ~from_status:task.task_status
                       ~to_status:
                         (Masc_domain.Cancelled
                            { cancelled_by = agent_name
                            ; cancelled_at = now_iso ()
                            ; reason = (if reason = "" then None else Some reason)
                            })
                       ?reason:(if reason = "" then None else Some reason)
                       ());
               observe_task_transition
                 config
                 ~agent_name
                 ~task_id
                 ~transition:Masc_domain.Cancel
                 ~details:
                   (task_transition_details
                      ~from_status:task.task_status
                      ~to_status:
                        (Masc_domain.Cancelled
                           { cancelled_by = agent_name
                           ; cancelled_at = now_iso ()
                           ; reason = (if reason = "" then None else Some reason)
                           })
                      ?reason:(if reason = "" then None else Some reason)
                      ~duration_ms:
                        (max
                           0
                           (int_of_float
                              ((Time_compat.now ()
                                -. task_started_at_unix task.task_status)
                               *. 1000.0)))
                      ());
               (* Hebbian: weaken only against agents with active tasks *)
               (try
                  let workers = working_agents config in
                  (Atomic.get Coord_hooks.hebbian_on_task_cancelled_fn)
                    config
                    ~agent_name
                    ~active_agents:workers
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  Log.RoomTask.error
                    "hebbian task_cancelled hook error: %s"
                    (Printexc.to_string exn));
               Ok (Printf.sprintf "%s cancelled %s" agent_name task_id)))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e)))))
;;

(* Scheduling functions are in Coord_task_schedule.
   Re-export claim_next_result from Types for backward compatibility. *)
type claim_next_result = Masc_domain.claim_next_result =
  | Claim_next_claimed of
      { task_id : string
      ; title : string
      ; priority : int
      ; released_task_id : string option
      ; message : string
      }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int }
  | Claim_next_error of string

let link_task_execution_artifacts_r
      config
      ~task_id
      ?session_id
      ?operation_id
      ?autoresearch_loop_id
      ()
  : string Masc_domain.masc_result
  =
  if not (is_initialized config)
  then Error (Masc_domain.System Masc_domain.System_error.NotInitialized)
  else (
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      try
        match read_backlog_r config with
        | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
        | Ok backlog ->
          (match List.find_opt (fun (task : task) -> task.id = task_id) backlog.tasks with
           | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
           | Some task ->
             let existing_contract =
               ensure_task_contract_for_verification
                 ?contract:task.contract
                 ~title:task.title
                 ~description:task.description
                 ()
             in
             let updated_contract =
               { existing_contract with
                 links =
                   merge_execution_links
                     existing_contract.links
                     ?session_id
                     ?operation_id
                     ?autoresearch_loop_id
                     ()
               }
               |> normalize_task_contract
             in
             let new_tasks =
               List.map
                 (fun (candidate : task) ->
                    if candidate.id = task_id
                    then { candidate with contract = Some updated_contract }
                    else candidate)
                 backlog.tasks
             in
             let new_backlog =
               { tasks = new_tasks
               ; last_updated = now_iso ()
               ; version = backlog.version + 1
               }
             in
             write_backlog config new_backlog;
             emit_task_activity
               config
               ~agent_name:"system"
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Linked)
               ~payload:
                 (`Assoc
                     ([ "task_id", `String task_id ]
                      @ (match trim_opt session_id with
                         | Some session_id -> [ "session_id", `String session_id ]
                         | None -> [])
                      @ (match trim_opt operation_id with
                         | Some operation_id -> [ "operation_id", `String operation_id ]
                         | None -> [])
                      @
                      match trim_opt autoresearch_loop_id with
                      | Some autoresearch_loop_id ->
                        [ "autoresearch_loop_id", `String autoresearch_loop_id ]
                      | None -> []));
             log_event
               config
               (`Assoc
                      ([ "type", `String "task_linked"
                       ; "agent", `String "system"
                       ; "actor_kind", `String "system"
                       ; "task", `String task_id
                       ; "ts", `String (now_iso ())
                       ]
                       @ (match trim_opt session_id with
                          | Some session_id -> [ "session_id", `String session_id ]
                          | None -> [])
                       @ (match trim_opt operation_id with
                          | Some operation_id -> [ "operation_id", `String operation_id ]
                          | None -> [])
                       @
                       match trim_opt autoresearch_loop_id with
                       | Some autoresearch_loop_id ->
                         [ "autoresearch_loop_id", `String autoresearch_loop_id ]
                       | None -> []));
             Ok (Printf.sprintf "Linked execution artifacts for %s" task_id))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e)))))
;;
