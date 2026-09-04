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

type verification_submission =
  { task : Masc_domain.task
  ; assignee : string
  ; verification_id : string
  ; claim : Masc_domain.verification_claim
  ; (* Set when the submission superseded a pending one, so the record it
       replaced can be removed after the commit. The task points only at the
       new id; leaving the old file behind would show the dashboard a request
       no task is waiting on. *)
    superseded_verification_id : string option
  }

(* Workspace-visible wording for a committed transition, or [None] when the
   action already reaches readers through a richer channel.

   [claim_task_r] broadcasts "Claimed <id>", but this entry point emitted only
   an activity event, so ownership changes taken through [masc_transition] left
   the workspace message log silent. Measured on the reference workspace:
   53 [task.cancelled] activity events in one month against 0 cancellation
   broadcasts, while the claim path produced 196. An operator reading the
   message log saw tasks get claimed and never saw one end, and a cancellation
   reason reached no reader at all.

   Exhaustive on [task_action]: a new action must state its own wording, or
   state which channel already carries it. [reason] rides along on the two
   actions that stop work in progress — it is the only place the "why" reaches
   a reader who is not polling the backlog.

   The "why" arrives on either of two arguments depending on the entry point.
   [release_task_r] takes no [reason] at all and forwards only
   [handoff_context], so the production release tool — which requires a handoff
   context for a strict release — reached this function with an empty [reason]
   and published a bare "Released <id>", dropping the explanation it was given.
   [Masc_domain.stated_reason] owns that rule so the author wake resolves the
   same "why" from the same task rather than reading only the status field. *)
let transition_broadcast_content ~new_status ~task_id ~reason ~handoff_context
  : string option
  =
  let with_reason verb =
    match Masc_domain.stated_reason ~reason:(Some reason) ~handoff_context with
    | None -> Some (Printf.sprintf "%s %s" verb task_id)
    | Some reason -> Some (Printf.sprintf "%s %s - %s" verb task_id reason)
  in
  (* The message says what happened to the Task, so it is read off the status
     the transition produced rather than the action that asked for it. Read off
     the action, [Cancel] announced "Cancelled" for a stop that had only been
     submitted — since a producer's stop waits for a verdict, that message
     named a terminal the Task had not reached and might never reach.

     Each status is produced by exactly one action, so nothing is lost:
     [Claimed] only by [Claim], [InProgress] only by [Start], [Todo] only by
     [Release], [Cancelled] only by a [Cancel] the authority approved or one on
     an unclaimed Task. The idempotent repeats ([Cancel] on [Cancelled],
     [Release] on [Todo]) are filtered as no-ops before this is reached. *)
  match (new_status : Masc_domain.task_status) with
  | Masc_domain.Claimed _ -> Some (Printf.sprintf "Claimed %s" task_id)
  | Masc_domain.InProgress _ -> Some (Printf.sprintf "Started %s" task_id)
  | Masc_domain.Cancelled _ -> with_reason "Cancelled"
  | Masc_domain.Todo -> with_reason "Released"
  (* A completion submission posts its request, criteria and evidence refs to
     Board through [Verification_protocol.notify_submit_for_verification]; a
     message row would restate a strictly poorer version of that post.

     A stop is the other way round. Its whole payload is one sentence, and the
     Board post carrying it is [Unlisted] — reachable by id, absent from the
     feed. The measurement that put cancellations in this log in the first
     place is the same one: a reason no reader sees is a reason that did not
     arrive. So it keeps its row, worded as the request it is. *)
  | Masc_domain.AwaitingVerification { intent = Masc_domain.Complete_task; _ } -> None
  | Masc_domain.AwaitingVerification { intent = Masc_domain.Cancel_task; _ } ->
    with_reason "Cancellation requested for"
  (* [Done] never reaches this commit: the lifecycle answers [Done_action] with
     [Verification_submission_required] from every non-terminal status, and
     Done→Done is filtered earlier as a no-op. Completion commits through
     [commit_verdict_r], which posts the verdict to Board. *)
  | Masc_domain.Done _ -> None
;;

let transition_task_outcome_r
      config
      ~agent_name
      ~task_id
      ~action
      ?prepare_verification_request
      ?expected_version
      ?(notes = "")
      ?(reason = "")
      ?handoff_context
      ()
  : transition_outcome Masc_domain.masc_result
  =
  (* The workspace API owns the task FSM, while persistence of the
     verification request remains behind the neutral hook registry. The
     caller may provide an explicit adapter, but omitting it must still use
     the installed runtime adapter; otherwise the FSM would create an
     [AwaitingVerification] state with no request for the system LLM authority
     to inspect. Which transitions need one is decided below from the state
     the lifecycle produced, not from the action that produced it. *)
  let prepare_verification_request =
    match prepare_verification_request with
    | Some prepare -> prepare
    | None ->
      fun ~task ~assignee ~verification_id ~claim ->
        (Atomic.get Workspace_hooks.verification_submit_request_fn)
          config
          ~task
          ~assignee
          ~verification_id
          ~claim
  in
  (* Compensation is not a caller's choice. Its result type is [unit], so a
     failed cleanup is logged by the adapter but cannot hide the original
     commit failure, and no caller ever had a reason to supply its own. *)
  let compensate_verification_request ~verification_id =
    (match
           (Atomic.get Workspace_hooks.verification_delete_request_fn)
             config
             ~verification_id
         with
         | Ok () -> ()
         | Error detail ->
           Log.TaskState.error
             "verification request compensation degraded task_id=%s verification_id=%s detail=%s"
             task_id
             verification_id
             detail)
  in
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
  let lock_path = backlog_lock_path config in
  let committed_verification_submission = ref None in
  let result =
    with_file_lock_r config lock_path (fun () ->
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
        (* The workspace FSM owns lifecycle and identity invariants. Completion
           evidence is submitted for an out-of-band authority verdict. *)
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
            | Masc_domain.Submit_for_verification ), _ -> Ok ())
          [@warning "-4"]
        in
        let now = now_iso () in
        let now_ts = Time_compat.now () in
        let action_s = Masc_domain.task_action_to_string action in
        let* decision =
          match
            Workspace_task_lifecycle.decide
              ~new_verification_id:(fun () -> Random_id.prefixed ~prefix:"vrf-" ~bytes:16)
              ~same_agent:(same_task_actor config agent_name)
              ~agent_name
              ~task_id
              ~task_status:task.task_status
              ~action
              ~now
              ~notes
              ~reason
          with
          | Ok decision -> Ok decision
          | Error Workspace_task_lifecycle.Verification_submission_required ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "Task completion must be submitted for verification; use \
                     submit_for_verification with evidence"))
          | Error Workspace_task_lifecycle.Verification_pending_verdict ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "Task %s awaits a completion authority's verdict and is not \
                        claimable by any agent (%s included). A Keeper is not a \
                        verifier."
                       task_id
                       agent_name)))
          | Error Workspace_task_lifecycle.Verdict_rejection_reason_required ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "a rejection verdict requires a non-empty reason explaining \
                     what must be fixed"))
          | Error Workspace_task_lifecycle.Verdict_authority_identity_required ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    "a completion verdict requires a non-empty authenticated \
                     authority identity"))
          | Error
              (Workspace_task_lifecycle.Verification_id_mismatch
                 { expected; actual }) ->
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "Task %s verification id mismatch (expected=%s current=%s)"
                       task_id
                       expected
                       actual)))
          | Error Workspace_task_lifecycle.Invalid_transition ->
            let assignee_hint =
              match task_assignee_of_status task.task_status with
              | Some a when not (same_task_actor config a agent_name) ->
                Printf.sprintf ", current_assignee=%s" a
              | _ -> ""
            in
(* Issue #7646: ownership-mismatch dominates; only show valid_next_actions when the failure isn't an ownership problem. *)
            let actions_hint =
              if assignee_hint <> ""
              then ""
              else
                next_actions_hint task.task_status
            in
            Error
              (Masc_domain.Task
                 (Masc_domain.Task_error.InvalidState
                    (Printf.sprintf
                       "Invalid transition: %s -> %s (%s, agent=%s%s%s)."
                       (task_status_to_string task.task_status)
                       action_s
                       task_id
                       agent_name
                       assignee_hint
                       actions_hint)))
        in
        let new_status = decision.Workspace_task_lifecycle.new_status in
        let set_current = decision.set_current in
        (* The obligation the lifecycle just created, if any. A completion
           carries the evidence references parsed from the notes and handoff;
           a stop carries the producer's reason. Keyed on the produced state so
           every path into [AwaitingVerification] writes the record the
           authority reads. Keyed on the action, the cancel path wrote none,
           and the authority deferred the Task on "verification not found"
           until an operator noticed (task-1303, 2026-09-03). *)
        let pending_verification =
          match new_status with
          | Masc_domain.AwaitingVerification
              { assignee; verification_id; intent = Masc_domain.Complete_task; _ } ->
            Some
              ( assignee
              , verification_id
              , Masc_domain.Completion_evidence
                  { evidence_refs =
                      Workspace_task_verification.verification_submission_evidence_refs
                        task
                        ~notes
                        handoff_context
                  } )
          | Masc_domain.AwaitingVerification
              { assignee; verification_id; intent = Masc_domain.Cancel_task; _ } ->
            (* The why arrives on either argument. [reason] is optional on this
               entry point while [handoff_context.summary] is required for every
               exit-class action, so a caller that put the whole explanation in
               the summary — which the tool schema told it to fill — has stated
               one. [stated_reason] is the same resolution the broadcast below
               uses; reading only [reason] here would refuse a cancellation the
               message log would then have announced with its reason. *)
            Some
              ( assignee
              , verification_id
              , Masc_domain.Cancellation_reason
                  { reason =
                      Option.value
                        ~default:""
                        (Masc_domain.stated_reason
                           ~reason:(Some reason)
                           ~handoff_context:
                             (match handoff_context with
                              | Some _ -> handoff_context
                              | None -> task.handoff_context))
                  } )
          | Masc_domain.Todo
          | Masc_domain.Claimed _
          | Masc_domain.InProgress _
          | Masc_domain.Done _
          | Masc_domain.Cancelled _ -> None
        in
        let* () =
          match pending_verification with
          | None -> Ok ()
          | Some (_, _, Masc_domain.Completion_evidence _) ->
            if String.length (String.trim notes) = 0
            then
              Error
                (Masc_domain.Task
                   (Masc_domain.Task_error.InvalidState
                      "submit_for_verification requires non-empty notes describing the \
                       deliverable and evidence references"))
            else Ok ()
          | Some (_, _, Masc_domain.Cancellation_reason { reason }) ->
            if String.length (String.trim reason) = 0
            then
              Error
                (Masc_domain.Task
                   (Masc_domain.Task_error.InvalidState
                      "cancel requires a stated reason: pass reason, or state it in \
                       handoff_context (summary or reason). The completion \
                       authority judges that sentence and nothing else"))
            else Ok ()
        in
        let* () =
          match pending_verification with
          | None -> Ok ()
          | Some (assignee, verification_id, claim) ->
            (match
               prepare_verification_request ~task ~assignee ~verification_id ~claim
             with
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
                          e))))
        in
        (match action, task.task_status with
         | Masc_domain.Release, Masc_domain.Todo ->
(* Idempotent: already in backlog, nothing to release. *)
           Log.TaskState.debug "release on already-todo task %s — no-op" task_id
        | Masc_domain.Claim, _
        | Masc_domain.Start, _
        | Masc_domain.Done_action, _
        | Masc_domain.Cancel, _
        | Masc_domain.Submit_for_verification, _
         | Masc_domain.Release, Masc_domain.Claimed _
         | Masc_domain.Release, Masc_domain.InProgress _
         | Masc_domain.Release, Masc_domain.AwaitingVerification _
         | Masc_domain.Release, Masc_domain.Done _
         | Masc_domain.Release, Masc_domain.Cancelled _ -> ());
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
             task outcome. A transition into [AwaitingVerification] writes the
             verification record before this commit (content the verifier
             reads); if the commit fails after the record was written,
             compensate by deleting the record so the record store and
             [task_status] are never left disagreeing, then surface the
             failure. Fiber cancellation is re-raised without compensating,
             because running store I/O inside a cancelled fiber is unsafe. The
             record it leaves is not always inert: cancelling a Task that was
             already awaiting writes a second record while the Task still
             points at the first, which is the two-open-requests shape the
             supersede delete below exists to prevent. The exposure predates
             this change — resubmission has always written before the commit —
             and the dashboard shows such a record while [decide_verdict]
             refuses any verdict carrying its id. *)
          (try write_backlog config backlog_update.backlog with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             (match pending_verification with
              | None -> ()
              | Some (_, verification_id, _) ->
                compensate_verification_request ~verification_id);
             raise exn);
          (match pending_verification with
           | None -> ()
           | Some (assignee, verification_id, claim) ->
             committed_verification_submission :=
               Some
                 { task = { task with task_status = new_status }
                 ; assignee
                 ; verification_id
                 ; claim
                 ; superseded_verification_id =
                     (match task.task_status with
                      | Masc_domain.AwaitingVerification
                          { verification_id = superseded; _ } ->
                        Some superseded
                      | Masc_domain.Todo
                      | Masc_domain.Claimed _
                      | Masc_domain.InProgress _
                      | Masc_domain.Done _
                      | Masc_domain.Cancelled _ -> None)
                 });
          (* RFC-0221 §3.3: clear stale agent task-cache entries AFTER the
             commit so agents that cache the task don't emit stale broadcasts
             referencing the old status. *)
          Task_cache_invariant.clear_stale_agent_task config
            ~cause:Task_cache_invariant.After_commit
            ~agent_name ~task_id ~status:new_status
            ~module_name:"transition_task_r";
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
               ?assignee:(Masc_domain.task_assignee_of_status task.task_status)
               ?notes:(trim_opt (Some notes))
               ?reason:(trim_opt (Some reason))
               ?handoff_context:backlog_update.persisted_handoff_context
               ());
          (* Post-commit projection, isolated like the terminal hook below. The
             backlog write already committed, so letting [broadcast] escape here
             would report a committed transition as [IoError] and skip both the
             activity event and [task_terminal_committed_fn] — the author would
             never be woken about a cancellation that did happen, which is the
             failure this change exists to remove. [Eio.Cancel.Cancelled] still
             propagates: a cancelled fiber must not be resumed. *)
          (match
             transition_broadcast_content
               ~new_status
               ~task_id
               ~reason
               ~handoff_context:backlog_update.persisted_handoff_context
           with
           | None -> ()
           | Some content ->
             (try
                match broadcast ~audience:System_record config ~from_agent:agent_name ~content with
                | Ok _ -> ()
                | Error error ->
                  Log.TaskState.error
                    "task transition committed but broadcast was not persisted task_id=%s agent=%s action=%s detail=%s"
                    task_id
                    agent_name
                    action_s
                    (broadcast_error_to_string error)
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                Log.TaskState.error
                  "task transition committed but broadcast failed task_id=%s \
                   agent=%s action=%s detail=%s"
                  task_id
                  agent_name
                  action_s
                  (Printexc.to_string exn)));
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
               ~payload);
             (match new_status with
              | Masc_domain.AwaitingVerification { assignee; verification_id; _ } ->
                (try
                   (Atomic.get Workspace_hooks.verification_submitted_fn)
                     config
                     ~task:{ task with task_status = new_status }
                     ~assignee
                     ~verification_id
                 with
                 | Eio.Cancel.Cancelled _ as exn -> raise exn
                 | exn ->
                   Log.TaskState.error
                     "verification authority scheduling degraded after submit commit \
                      task_id=%s verification_id=%s detail=%s"
                     task_id
                     verification_id
                     (Printexc.to_string exn))
              | Masc_domain.Todo
              | Masc_domain.Claimed _
              | Masc_domain.InProgress _
              | Masc_domain.Done _
              | Masc_domain.Cancelled _ -> ());
          (* RFC-0323 G-3: completion side effects key off the RESULT (Done), not
             the action — a verdict-produced completion arrives through
             [decide_verdict] and never as an agent action, so keying off the
             action would record no duration for it. The value measures the last
             status phase (started_at for in_progress, submitted_at for
             awaiting_verification). *)
          let completes_task =
            Masc_domain.task_status_is_done new_status
            && not (Masc_domain.task_status_is_done task.task_status)
          in
          let became_terminal =
            Masc_domain.task_status_is_terminal new_status
            && not (Masc_domain.task_status_is_terminal task.task_status)
          in
          if became_terminal
          then (
            let delivery =
              try
                (Atomic.get Workspace_hooks.task_terminal_committed_fn)
                  config
                  ~agent_name
                  ~task_id
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                Workspace_hooks.Task_terminal_delivery_degraded
                  { kind = "hook_exception"; detail = Printexc.to_string exn }
            in
            match delivery with
            | Workspace_hooks.Task_terminal_delivered -> ()
            | Workspace_hooks.Task_terminal_delivery_degraded { kind; detail } ->
              Log.TaskState.error
                "task terminal commit succeeded but reconciliation delivery degraded \
                 task_id=%s agent=%s kind=%s detail=%s"
                task_id
                agent_name
                kind
                detail);
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
              | Masc_domain.Submit_for_verification -> None)
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
                 ());
          (* RFC-0323 G-3: done hooks (relation/hebbian) fire for every transition
             that PRODUCES Done, including a Done produced by an approval verdict.
             The completer is the Done record's assignee — never the actor, which
             for a verdict is a completion authority rather than an agent. *)
          (match new_status with
           | Masc_domain.Done { assignee; _ } ->
             if completes_task
             then
               Workspace_task_cleanup.run_done_hooks config ~agent_name:assignee
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
           | Masc_domain.Submit_for_verification -> ());
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
  in
  (match !committed_verification_submission with
   | None -> ()
   | Some { task; assignee; verification_id; claim; superseded_verification_id }
     ->
     (* Order matters: remove the superseded record before announcing the new
        one, so no reader woken by the notification can see two open requests
        for one task. A failed removal leaves a request no task points at --
        visible in the dashboard, refused by [decide_verdict] on the id -- which
        is why it degrades rather than failing the committed transition. *)
     (match superseded_verification_id with
      | None -> ()
      | Some superseded ->
        (match
           (Atomic.get Workspace_hooks.verification_delete_request_fn) config
             ~verification_id:superseded
         with
         | Ok () -> ()
         | Error detail ->
           Log.TaskState.error
             "verification supersede delete degraded after commit task_id=%s \
              superseded=%s replaced_by=%s detail=%s"
             task_id
             superseded
             verification_id
             detail));
     (try
        (Atomic.get Workspace_hooks.verification_notify_submit_fn)
          config
          ~task
          ~assignee
          ~verification_id
          ~claim
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.TaskState.error
          "verification submit notification degraded after commit task_id=%s verification_id=%s detail=%s"
          task_id
          verification_id
          (Printexc.to_string exn)));
  result
;;

let transition_task_r
      config
      ~agent_name
      ~task_id
      ~action
      ?prepare_verification_request
      ?expected_version
      ?notes
      ?reason
      ?handoff_context
      ()
  : string Masc_domain.masc_result
  =
  transition_task_outcome_r
    config
    ~agent_name
    ~task_id
    ~action
    ?prepare_verification_request
    ?expected_version
    ?notes
    ?reason
    ?handoff_context
    ()
  |> Result.map (fun outcome -> outcome.message)
;;

(** Commit a completion verdict issued by a [Masc_domain.completion_authority].

    A separate entry from {!transition_task_outcome_r} because a verdict is not an
    agent action. The caller authenticates the authority before constructing
    this provenance value; the Keeper task-action surface has no verdict arm.

    This path is what keeps an [AwaitingVerification] obligation resolvable.
    Removing the verifier-as-keeper route without it would leave every pending
    obligation with no resolver, which is a fleet stop rather than a fix. *)
let commit_verdict_r
      config
      ~(authority : Masc_domain.completion_authority)
      ~(verdict : Masc_domain.completion_verdict)
      ~task_id
      ~verification_id
      ?(notes = "")
      ?evaluator_runtime
      ()
  : transition_outcome Masc_domain.masc_result
  =
  let open Result.Syntax in
  let* () =
    if not (is_initialized config)
    then Error (Masc_domain.System Masc_domain.System_error.NotInitialized)
    else Ok ()
  in
  let* () =
    match validate_task_id_r task_id with
    | Error e -> Error e
    | Ok _ -> Ok ()
  in
  let lock_path = backlog_lock_path config in
  with_file_lock_r config lock_path (fun () ->
    try
      match read_backlog_r config with
      | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
      | Ok backlog ->
        (match
           List.find_opt (fun (t : task) -> String.equal t.id task_id) backlog.tasks
         with
         | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
         | Some task ->
           let now = now_iso () in
           let* decided =
             match
               Workspace_task_lifecycle.decide_verdict
                 ~authority
                 ~verdict
                 ~task_id
                 ~verification_id
                 ~task_status:task.task_status
                 ~now
                 ~notes
             with
             | Ok decided -> Ok decided
             | Error Workspace_task_lifecycle.Verdict_rejection_reason_required ->
               Error
                 (Masc_domain.Task
                    (Masc_domain.Task_error.InvalidState
                       "a rejection verdict requires a non-empty reason explaining \
                        what must be fixed"))
             | Error Workspace_task_lifecycle.Verdict_authority_identity_required ->
               Error
                 (Masc_domain.Task
                    (Masc_domain.Task_error.InvalidState
                        "a completion verdict requires a non-empty authenticated \
                        authority identity"))
             | Error
                 (Workspace_task_lifecycle.Verification_id_mismatch
                    { expected; actual }) ->
               Error
                 (Masc_domain.Task
                    (Masc_domain.Task_error.InvalidState
                       (Printf.sprintf
                          "Task %s verification id mismatch (expected=%s current=%s)"
                          task_id
                          expected
                          actual)))
             | Error Workspace_task_lifecycle.Verification_pending_verdict
             | Error Workspace_task_lifecycle.Verification_submission_required
             | Error Workspace_task_lifecycle.Invalid_transition ->
               Error
                 (Masc_domain.Task
                    (Masc_domain.Task_error.InvalidState
                       (Printf.sprintf
                          "Task %s is %s; a completion verdict applies only to an \
                           obligation awaiting one"
                          task_id
                          (task_status_to_string task.task_status))))
           in
           let new_status = decided.Workspace_task_lifecycle.decision.new_status in
           let authority = decided.Workspace_task_lifecycle.authority in
           let authority_kind = Masc_domain.completion_authority_kind authority in
           let authority_actor = Masc_domain.completion_authority_actor authority in
           let authority_actor_kind =
             match authority with
             | Masc_domain.Human_operator _ -> Workspace_task_classify.Operator
             | Masc_domain.System_llm_agent _ -> Workspace_task_classify.System
           in
           let producer = decided.Workspace_task_lifecycle.producer in
           let verification_id = decided.Workspace_task_lifecycle.verification_id in
           let rejection_handoff =
             match verdict with
             | Masc_domain.Verdict_approved -> None
             | Masc_domain.Verdict_rejected { reason } ->
               Some
                 { Masc_domain.summary = reason
                 ; reason = Some reason
                 ; next_step = None
                 ; failure_mode = None
                 ; reclaim_policy = None
                 ; evidence_refs = [ verification_id ]
                 ; updated_at = Some now
                 ; updated_by = Some authority_actor
                 }
           in
           let new_backlog =
             { backlog with
               tasks =
                 List.map
                   (fun (t : task) ->
                      if String.equal t.id task_id
                      then
                        { t with
                          task_status = new_status
                        ; handoff_context = rejection_handoff
                        }
                      else t)
                   backlog.tasks
             }
           in
           (* [write_backlog] stamps version/last_updated at the commit point. *)
           write_backlog config new_backlog;
           let run_post_commit label f =
             try f () with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
               Log.TaskState.error
                 "completion verdict committed but post-commit projection failed \
                  task_id=%s authority=%s label=%s detail=%s"
                 task_id
                 authority_actor
                 label
                 (Printexc.to_string exn)
           in
           run_post_commit "producer_task_binding" (fun () ->
             match decided.Workspace_task_lifecycle.decision.set_current with
             | Some current_task ->
               update_local_agent_state config ~agent_name:producer (fun agent ->
                 { agent with status = Busy; current_task = Some current_task })
             | None ->
               Task_cache_invariant.clear_stale_agent_task
                 config
                 ~cause:Task_cache_invariant.After_commit
                 ~agent_name:producer
                 ~task_id
                 ~status:new_status
                 ~module_name:"commit_verdict_r");
           (* Completion hooks key off the RESULT, and the completer is the
              producer — never the authority, which is not an agent and owns no
              task. *)
           (match new_status with
            | Masc_domain.Done { assignee; _ } ->
              (* The observation surface has the same gap the completion metric
                 below records: a verdict does not pass through the agent
                 transition surface, so nothing emitted the audit entry or the
                 [Task_completed] telemetry for a task finished this way. The
                 audit trail stopped at [submit_for_verification] and never said
                 who approved the completion. RFC-0323 G-3 already states that a
                 Done produced by an approval verdict is a Done like any other,
                 and the actor is the record's assignee — the authority is not an
                 agent. [authority] rides in the details so the trail keeps the
                 provenance the actor field cannot carry. *)
              run_post_commit "transition_observation" (fun () ->
                observe_task_transition
                  config
                  ~agent_name:assignee
                  ~task_id
                  ~transition:Masc_domain.Done_action
                  ~details:
                    (let base =
                       task_transition_details
                         ~from_status:task.task_status
                         ~to_status:new_status
                         ?notes:(if notes = "" then None else Some notes)
                         ?duration_ms:
                           (Some
                              (max
                                 0
                                 (int_of_float
                                    ((Time_compat.now ()
                                      -. task_started_at_unix task.task_status)
                                     *. 1000.0))))
                         ()
                     in
                     match base with
                     | `Assoc fields ->
                       `Assoc (fields @ [ "authority", `String authority_actor ])
                     | other -> other));
              run_post_commit "terminal_reconciliation" (fun () ->
                match
                  (Atomic.get Workspace_hooks.task_terminal_committed_fn)
                    config
                    ~agent_name:assignee
                    ~task_id
                with
                | Workspace_hooks.Task_terminal_delivered -> ()
                | Workspace_hooks.Task_terminal_delivery_degraded { kind; detail } ->
                  Log.TaskState.error
                    "task verdict terminal reconciliation degraded task_id=%s \
                     producer=%s kind=%s detail=%s"
                    task_id
                    assignee
                    kind
                    detail);
              run_post_commit "done_hooks" (fun () ->
                Workspace_task_cleanup.run_done_hooks config ~agent_name:assignee);
              (* Completion metrics must fire on this path too. They used to be
                 emitted from the agent transition surface, which a verdict no
                 longer passes through — without this a verdict-completed task
                 would record no completion at all. [collaborators] is empty by
                 construction: the authority is not an agent and does not
                 collaborate on the task. *)
              run_post_commit "completion_metric" (fun () ->
                (Atomic.get Workspace_hooks.record_task_metric_fn)
                  config
                  ~agent_id:assignee
                  ~task_id
                  ~started_at:(task_started_at_unix task.task_status)
                  ~completed_at:(Some (Time_compat.now ()))
                  ~success:true
                  ~error_message:None
                  ~collaborators:[]
                  ~handoff_from:None
                  ~handoff_to:None)
            | Masc_domain.Todo
            | Masc_domain.Claimed _
            | Masc_domain.InProgress _
            | Masc_domain.AwaitingVerification _
            | Masc_domain.Cancelled _ -> ());
           let event_kind =
             match verdict with
             | Masc_domain.Verdict_approved -> Event_kind.Task.Approved
             | Masc_domain.Verdict_rejected _ -> Event_kind.Task.Rejected
           in
           (* [authority_actor] is a fresh id per review, so it identifies the
              run and nothing else — grouping 74 verdicts by it yields 74 groups.
              [evaluator_runtime] is the config key that bound the provider and
              model which judged, so it is the axis a verdict history can
              actually be aggregated on. It was already computed and carried in
              the review notes blob; every structured projection dropped it.
              [None] for a human operator verdict, where no evaluator ran. *)
           let evaluator_runtime_field =
             match evaluator_runtime with
             | None -> []
             | Some runtime -> [ "evaluator_runtime", `String runtime ]
           in
           let authority_fields =
             [ "task_id", `String task_id
             ; "authority_kind", `String authority_kind
             ; "authority_actor", `String authority_actor
             ; "producer", `String producer
             ; "verification_id", `String verification_id
             ]
             @ evaluator_runtime_field
           in
           (* The task status deliberately stays a small lifecycle sum: a
              rejection returns the producer to [InProgress]. Keep the
              verdict and its reason in every durable/observable projection so
              a failed Board, SSE, or producer-wake projection cannot erase
              what the completion authority decided. *)
           let verdict_fields =
             match verdict with
             | Masc_domain.Verdict_approved ->
               [ "verdict", `String "approved" ]
             | Masc_domain.Verdict_rejected { reason } ->
               [ "verdict", `String "rejected"; "reason", `String reason ]
           in
           let completion_verdict_fields = authority_fields @ verdict_fields in
           run_post_commit "task_activity" (fun () ->
             emit_task_activity
               config
               ~actor_kind:authority_actor_kind
               ~agent_name:authority_actor
               ~task_id
               ~kind:(Event_kind.Task.to_string event_kind)
               ~payload:(`Assoc completion_verdict_fields));
           run_post_commit "verification_notification" (fun () ->
             let decision =
               match verdict with
               | Masc_domain.Verdict_approved -> `Approve notes
               | Masc_domain.Verdict_rejected { reason } -> `Reject reason
             in
             (Atomic.get Workspace_hooks.verification_notify_verdict_fn)
               ~task_id
               ~authority
               ~verification_id
               ~decision);
           run_post_commit "task_transition_subscription" (fun () ->
             (Atomic.get Workspace_hooks.push_task_event_fn)
               ~event_type:"masc/task_transition"
               ~details:
                 ([ "task_id", `String task_id
                  ; "action", `String "completion_verdict"
                  ; "authority_kind", `String authority_kind
                  ; "authority_actor", `String authority_actor
                  ; "verification_id", `String verification_id
                  ]
                  @ verdict_fields));
           (* Authority provenance is recorded here as structured fields. It is
              deliberately NOT written into [Done.notes]: the previous code put
              "Verified by <keeper> (vrf:<id>)" in that human-readable string,
              making it the only record of who approved, and nothing parsed it. *)
           run_post_commit "verdict_audit" (fun () ->
             log_event
               config
               (`Assoc
                 (("type", `String "task_completion_verdict")
                  :: ("from_status", `String (task_status_to_string task.task_status))
                  :: ("to_status", `String (task_status_to_string new_status))
                  :: ("ts", `String now)
                  :: completion_verdict_fields)));
           Ok
             { message =
                 Printf.sprintf
                   "%s %s → %s (verdict by %s)"
                   task_id
                   (task_status_to_string task.task_status)
                   (task_status_to_string new_status)
                   authority_kind
             ; noop = false
             })
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e))))
  |> Workspace_task_verification.flatten_lock_result
;;
