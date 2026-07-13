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

type task_reconciliation_signal =
  | Assignee_absent
  | Assignee_inactive

let reconciliation_signal_to_string = function
  | Assignee_absent -> "assignee_absent"
  | Assignee_inactive -> "assignee_inactive"
;;

let reconciliation_signal_holds config ~expected_assignee = function
  | Assignee_absent ->
    let all = Workspace_query.get_all_agents config in
    let active = Workspace_query.get_active_agents config in
    not
      (List.exists
         (fun (agent : Masc_domain.agent) ->
            same_task_actor config agent.name expected_assignee)
         (all @ active))
  | Assignee_inactive ->
    Workspace_query.get_all_agents config
    |> List.exists (fun (agent : Masc_domain.agent) ->
         same_task_actor config agent.name expected_assignee
         && agent.status = Masc_domain.Inactive)
;;

(** Reconcile one orphaned task without impersonating an actor. The service
    validates both the exact expected owner and an objective absent/inactive
    observation while holding the backlog lock. *)
let reconcile_orphaned_task_r
      config
      ~task_id
      ~expected_assignee
      ~signal
      ()
  : string Masc_domain.masc_result
  =
  let open Result.Syntax in
  let* _task_id = validate_task_id_r task_id in
  let* _expected_assignee = validate_agent_name_r expected_assignee in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock_r config backlog_path (fun () ->
    let* backlog =
      read_backlog_r config
      |> Result.map_error (fun message ->
        Masc_domain.System (Masc_domain.System_error.IoError message))
    in
    let* task =
      match List.find_opt (fun (task : task) -> String.equal task.id task_id) backlog.tasks with
      | Some task -> Ok task
      | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
    in
    let* actual_assignee =
      match task_assignee_of_status task.task_status with
      | Some assignee -> Ok assignee
      | None ->
        Error
          (Masc_domain.Task
             (Masc_domain.Task_error.InvalidState
                (Printf.sprintf "Task %s has no reconcilable assignee" task_id)))
    in
    let* () =
      if String.equal actual_assignee expected_assignee
      then Ok ()
      else
        Error
          (Masc_domain.Task
             (Masc_domain.Task_error.InvalidState
                (Printf.sprintf
                   "Task %s assignee changed (expected %s, found %s)"
                   task_id
                   expected_assignee
                   actual_assignee)))
    in
    let* () =
      match task.task_status with
      | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> Ok ()
      | Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ->
        Error
          (Masc_domain.Task
             (Masc_domain.Task_error.InvalidState
                (Printf.sprintf
                   "Task %s status %s is not orphan-reconcilable"
                   task_id
                   (task_status_to_string task.task_status))))
    in
    let* () =
      if reconciliation_signal_holds config ~expected_assignee signal
      then Ok ()
      else
        Error
          (Masc_domain.Task
             (Masc_domain.Task_error.InvalidState
                (Printf.sprintf
                   "Task %s reconciliation signal %s is not true for %s"
                   task_id
                   (reconciliation_signal_to_string signal)
                   expected_assignee)))
    in
    let updated_tasks =
      List.map
        (fun (candidate : task) ->
           if String.equal candidate.id task_id
           then { candidate with task_status = Masc_domain.Todo }
           else candidate)
        backlog.tasks
    in
    write_backlog
      config
      { tasks = updated_tasks
      ; last_updated = now_iso ()
      ; version = backlog.version + 1
      };
    Task_cache_invariant.clear_stale_agent_task
      config
      ~agent_name:expected_assignee
      ~task_id
      ~status:Masc_domain.Todo
      ~module_name:"reconcile_orphaned_task_r";
    log_event
      config
      (`Assoc
          [ "type", `String "task_orphan_reconciled"
          ; "task", `String task_id
          ; "expected_assignee", `String expected_assignee
          ; "signal", `String (reconciliation_signal_to_string signal)
          ; "ts", `String (now_iso ())
          ]);
    Ok (Printf.sprintf "Task %s reconciled to todo" task_id))
  |> Workspace_task_verification.flatten_lock_result
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
