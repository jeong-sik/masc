(** Workspace_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next.

    Facade module: includes Workspace_task_transitions (which includes classify,
    create, claim sub-modules). *)

open Masc_domain
open Workspace_backlog

include Workspace_task_transitions

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
    ~authority:Masc_domain.System
    ()
;;

(** Force-done a task regardless of assignee. Keeper privilege. *)
let force_done_task_r config ~agent_name ~task_id ~notes ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Done_action
    ~notes
    ~authority:Masc_domain.System
    ()
;;

type machine_verify_failure =
  | Machine_verify_invalid_verifier of string
  | Machine_verify_verifier_not_distinct of
      { agent_name : string
      ; verifier_name : string
      }
  | Machine_verify_submit_failed of Masc_domain.masc_error
  | Machine_verify_approve_failed_compensated of Masc_domain.masc_error
  | Machine_verify_approve_failed_stranded of
      { approve_error : Masc_domain.masc_error
      ; reject_error : Masc_domain.masc_error
      }

let machine_verify_compensation_reason =
  "machine verification approve failed; compensating reject"
;;

(** RFC-0323 G-2: machine-verified completion through the verification lane.

    Submits as [agent_name] (must be the assignee; the FSM submit arm enforces
    it), then approves as [verifier_name] — a distinct machine identity, since
    the FSM self-approval check compares identity keys and never authority.
    Both preconditions (verifier name shape, verifier distinct from submitter)
    are checked before any state mutation.

    Verification-store lifecycle mirrors the tool layer (RFC-0221): the
    request record is created before the submit commit and deleted if that
    commit fails; a successful approve (or compensating reject) records the
    machine verdict, resolving the record. Board/SSE notify hooks are
    deliberately not invoked — machine completions do not announce; the store
    record is the audit trail. Hook defaults are no-ops, so contexts without
    the verification store stay store-free.

    If the approve fails after a successful submit, one compensating reject
    (as [verifier_name]) returns the task to [InProgress { assignee }]. If
    that also fails, the task stays [AwaitingVerification] and the Pending
    store record is deliberately left in place: the task remains inside the
    pending-verification wake signal and the dashboard verification panel, so
    any other identity can approve/reject it through the normal lane. *)
let submit_and_approve_task_r
      config
      ~agent_name
      ~verifier_name
      ~task_id
      ~notes
      ~approve_notes
      ()
  : (string, machine_verify_failure) result
  =
  match Validation.Agent_id.validate verifier_name with
  | Error msg -> Error (Machine_verify_invalid_verifier msg)
  | Ok _ ->
    if Workspace_task_classify.same_task_actor config verifier_name agent_name
    then Error (Machine_verify_verifier_not_distinct { agent_name; verifier_name })
    else (
      let prepare_verification_request ~task ~assignee ~verification_id ~evidence_refs =
        (Atomic.get Workspace_hooks.verification_submit_request_fn)
          config
          ~task
          ~assignee
          ~verification_id
          ~evidence_refs
      in
      let compensate_verification_request ~verification_id =
        match
          (Atomic.get Workspace_hooks.verification_delete_request_fn)
            config
            ~verification_id
        with
        | Ok () -> ()
        | Error e ->
          Log.Workspace.warn
            "machine-verify submit compensation failed (task=%s vrf=%s): %s"
            task_id
            verification_id
            e
      in
      match
        transition_task_r
          config
          ~agent_name
          ~task_id
          ~action:Masc_domain.Submit_for_verification
          ~notes
          ~prepare_verification_request
          ~compensate_verification_request
          ()
      with
      | Error e -> Error (Machine_verify_submit_failed e)
      | Ok _submitted ->
        let verification_id =
          match read_backlog_r config with
          | Error _ -> None
          | Ok backlog ->
            (match
               List.find_opt
                 (fun (t : Masc_domain.task) -> String.equal t.id task_id)
                 backlog.tasks
             with
             | None -> None
             | Some t ->
               (match t.task_status with
                | Masc_domain.AwaitingVerification { verification_id; _ } ->
                  Some verification_id
                | Masc_domain.Todo
                | Masc_domain.Claimed _
                | Masc_domain.InProgress _
                | Masc_domain.Done _
                | Masc_domain.Cancelled _ -> None))
        in
        let record_verdict decision =
          match verification_id with
          | None ->
            Log.Workspace.warn
              "machine-verify: verification id unreadable after submit \
               (task=%s); a store record may remain pending"
              task_id
          | Some verification_id ->
            (match
               (Atomic.get Workspace_hooks.verification_record_verdict_fn)
                 config
                 ~task_id
                 ~verifier:verifier_name
                 ~verification_id
                 ~decision
             with
             | Ok () -> ()
             | Error e ->
               Log.Workspace.warn
                 "machine-verify verdict record failed (task=%s vrf=%s): %s"
                 task_id
                 verification_id
                 e)
        in
        (match
           transition_task_r
             config
             ~agent_name:verifier_name
             ~task_id
             ~action:Masc_domain.Approve_verification
             ~notes:approve_notes
             ()
         with
         | Ok message ->
           record_verdict (`Approve approve_notes);
           Ok message
         | Error approve_error ->
           (match
              transition_task_r
                config
                ~agent_name:verifier_name
                ~task_id
                ~action:Masc_domain.Reject_verification
                ~reason:machine_verify_compensation_reason
                ()
            with
            | Ok _ ->
              record_verdict (`Reject machine_verify_compensation_reason);
              Error (Machine_verify_approve_failed_compensated approve_error)
            | Error reject_error ->
              (* Deliberately no record cleanup: the Pending record keeps the
                 stranded task actionable for the pending-verification wake
                 signal and the dashboard verification panel. *)
              Error
                (Machine_verify_approve_failed_stranded { approve_error; reject_error }))))
;;

(** Force-cancel a task regardless of assignee. System privilege.
    Used by [Verification_protocol.check_timeouts] to expire
    [AwaitingVerification] tasks whose verifier deadline has passed,
    so the FSM does not stall and re-emit Timeout posts forever. *)
let force_cancel_task_r config ~agent_name ~task_id ~reason ()
  : string Masc_domain.masc_result
  =
  transition_task_r
    config
    ~agent_name
    ~task_id
    ~action:Masc_domain.Cancel
    ~reason
    ~authority:Masc_domain.System
    ()
;;

let cancel_task_r config ~agent_name ~task_id ~reason : string Masc_domain.masc_result =
  if not (is_initialized config)
  then Error (Masc_domain.System Masc_domain.System_error.NotInitialized)
  else (
    let agent_name = resolve_agent_name_strict config agent_name in
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    let result =
      with_file_lock_r config backlog_path (fun () ->
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
                 (Masc_domain.Task
                    (Masc_domain.Task_error.InvalidState
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
                        (* Cancellation is terminal by status. Clear reclaim
                           policy so that re-opened tasks remain claimable.
                           Previously Block_reclaim was preserved here (RFC-0288
                           constraint turn=24), causing permanently unclaimable
                           tasks after Cancelled→Todo re-open. *)
                        let reclaim_policy, do_not_reclaim_reason = None, None in
                        { t with
                          task_status =
                            Masc_domain.Cancelled
                              { cancelled_by = agent_name
                              ; cancelled_at = now_iso ()
                              ; reason = (if reason = "" then None else Some reason)
                              }
                        ; cycle_count = new_cycle
                        ; reclaim_policy
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
               write_backlog
                 ~after_commit:(fun () ->
                   Task_cache_invariant.clear_stale_agent_task config
                     ~agent_name ~task_id
                     ~status:(Cancelled { cancelled_by = agent_name; cancelled_at = now_iso (); reason = Some reason })
                     ~module_name:"cancel_task_r")
                 config new_backlog;
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
                  (Atomic.get Workspace_hooks.hebbian_on_task_cancelled_fn)
                    config
                    ~agent_name
                    ~active_agents:workers
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  Log.TaskState.error
                    "hebbian task_cancelled hook error: %s"
                    (Printexc.to_string exn));
               Ok (Printf.sprintf "%s cancelled %s" agent_name task_id)))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e ->
        Error
          (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e))))
    in
    Workspace_task_verification.flatten_lock_result result)
;;

(* Scheduling functions are in Workspace_task_schedule.
   Re-export claim_next_result from Types for backward compatibility. *)
type claim_next_result = Masc_domain.claim_next_result =
  | Claim_next_claimed of
      { task_id : string
      ; title : string
      ; priority : int
      ; released_task_id : string option
      ; message : string
      ; scope_widened : bool
      }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of
      { excluded_count : int
      ; blocked_count : int
      ; verification_blocked_count : int
      ; scope_excluded_count : int
      ; explicit_excluded_count : int
      ; claim_pool_candidate_count : int
      }
  | Claim_next_error of string

let link_task_execution_artifacts_r
      config
      ~task_id
      ?session_id
      ?operation_id
      ()
  : string Masc_domain.masc_result
  =
  if not (is_initialized config)
  then Error (Masc_domain.System Masc_domain.System_error.NotInitialized)
  else (
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    let result =
      with_file_lock_r config backlog_path (fun () ->
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
             let execution_link_fields =
               (match trim_opt session_id with
                | Some session_id -> [ "session_id", `String session_id ]
                | None -> [])
               @
               match trim_opt operation_id with
               | Some operation_id -> [ "operation_id", `String operation_id ]
               | None -> []
             in
             emit_task_activity
               config
               ~agent_name:"system"
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Linked)
               ~payload:(`Assoc ([ "task_id", `String task_id ] @ execution_link_fields));
             log_event
               config
               (`Assoc
                   ([ "type", `String "task_linked"
                    ; "agent", `String "system"
                    ; "actor_kind", `String "system"
                    ; "task", `String task_id
                    ; "ts", `String (now_iso ())
                    ]
                    @ execution_link_fields));
             Ok (Printf.sprintf "Linked execution artifacts for %s" task_id))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e ->
        Error
          (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e))))
    in
    Workspace_task_verification.flatten_lock_result result)
;;
