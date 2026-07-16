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

type operator_task_recovery_result =
  { task_id : string
  ; previous_status : Masc_domain.task_status
  ; previous_assignee : string
  ; backlog_version : int
  ; post_commit_errors : string list
  }

let recover_owned_task_to_todo_r
      config
      ~operator_actor
      ~task_id
      ~expected_assignee
      ~expected_version
      ~reason
      ()
  : operator_task_recovery_result Masc_domain.masc_result
  =
  let open Result.Syntax in
  let* () =
    if not (is_initialized config)
    then Error (Masc_domain.System Masc_domain.System_error.NotInitialized)
    else Ok ()
  in
  let* _task_id = validate_task_id_r task_id in
  let* _expected_assignee = validate_agent_name_r expected_assignee in
  let* () =
    if String.equal operator_actor (String.trim operator_actor)
       && not (String.equal operator_actor "")
    then Ok ()
    else
      Error
        (Masc_domain.System
           (Masc_domain.System_error.ValidationError
              "operator_actor must be non-empty without surrounding whitespace"))
  in
  let* () =
    if String.equal reason (String.trim reason) && not (String.equal reason "")
    then Ok ()
    else
      Error
        (Masc_domain.System
           (Masc_domain.System_error.ValidationError
              "reason must be non-empty without surrounding whitespace"))
  in
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock_r config backlog_path (fun () ->
    let open Result.Syntax in
    let* backlog =
      read_backlog_r config
      |> Result.map_error (fun message ->
        Masc_domain.System (Masc_domain.System_error.IoError message))
    in
    let* () =
      if backlog.version = expected_version
      then Ok ()
      else
        Error
          (Masc_domain.Task
             (Masc_domain.Task_error.InvalidState
                (Printf.sprintf
                   "Task recovery version mismatch (expected %d, got %d)"
                   expected_version
                   backlog.version)))
    in
    let* task =
      match List.find_opt (fun (task : task) -> String.equal task.id task_id) backlog.tasks with
      | Some task -> Ok task
      | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
    in
    let* previous_assignee =
      match task.task_status with
      | Masc_domain.Claimed { assignee; _ }
      | Masc_domain.InProgress { assignee; _ } ->
        Ok assignee
      | Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ->
        Error
          (Masc_domain.Task
             (Masc_domain.Task_error.InvalidState
                (Printf.sprintf
                   "Task %s status %s is not operator-recoverable"
                   task_id
                   (Masc_domain.task_status_to_string task.task_status))))
    in
    let* () =
      if String.equal previous_assignee expected_assignee
      then Ok ()
      else
        Error
          (Masc_domain.Task
             (Masc_domain.Task_error.InvalidState
                (Printf.sprintf
                   "Task %s assignee mismatch (expected %s, got %s)"
                   task_id
                   expected_assignee
                   previous_assignee)))
    in
    let tasks =
      List.map
        (fun (candidate : task) ->
           if String.equal candidate.id task_id
           then
             { candidate with
               task_status = Masc_domain.Todo
             ; reclaim_policy = None
             ; do_not_reclaim_reason = None
             }
           else candidate)
        backlog.tasks
    in
    let backlog_version = backlog.version + 1 in
    let* persistence =
      write_backlog_result
        config
        { tasks; last_updated = now_iso (); version = backlog_version }
      |> Result.map_error (fun message ->
        Masc_domain.System (Masc_domain.System_error.IoError message))
    in
    let run_post_commit label f =
      try
        f ();
        None
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        let detail = Printf.sprintf "%s: %s" label (Printexc.to_string exn) in
        Log.TaskState.error
          "operator task recovery post-commit projection failed task=%s \
           version=%d detail=%s"
          task_id
          backlog_version
          detail;
        Some detail
    in
    let post_commit_errors =
      [ Option.map
          (fun message -> "backlog_primary_mirror: " ^ message)
          persistence.primary_mirror_error
      ; Option.map
          (fun message -> "backlog_recovery_copy: " ^ message)
          persistence.recovery_error
      ; Option.map
          (fun message -> "backlog_post_commit: " ^ message)
          persistence.post_commit_error
      ; run_post_commit "task_cache_invariant" (fun () ->
          Task_cache_invariant.clear_stale_agent_task
            config
            ~agent_name:previous_assignee
            ~task_id
            ~status:Masc_domain.Todo
            ~module_name:"recover_owned_task_to_todo_r")
      ; run_post_commit "agent_state" (fun () ->
          update_local_agent_state config ~agent_name:previous_assignee (fun agent ->
            if agent.current_task = Some task_id
            then { agent with status = Active; current_task = None }
            else agent))
      ; run_post_commit "transition_log" (fun () ->
          log_event
            config
            (transition_log_event
               ~event_type:Task_transition
               ~actor_kind:Operator
               ~agent_name:operator_actor
               ~task_id
               ~from_status:task.task_status
               ~to_status:Masc_domain.Todo
               ~action:(Masc_domain.task_action_to_string Masc_domain.Release)
               ~reason
               ~assignee:previous_assignee
               ()))
      ; run_post_commit "task_activity" (fun () ->
          emit_task_activity
            ~actor_kind:Operator
            config
            ~agent_name:operator_actor
            ~task_id
            ~kind:(Event_kind.Task.to_string Event_kind.Task.Released)
            ~payload:
              (`Assoc
                [ "task_id", `String task_id
                ; "operator_recovery", `Bool true
                ; "previous_assignee", `String previous_assignee
                ; "reason", `String reason
                ; "backlog_version", `Int backlog_version
                ]))
      ; run_post_commit "transition_observer" (fun () ->
          observe_task_transition
            config
            ~agent_name:operator_actor
            ~task_id
            ~transition:Masc_domain.Release
            ~details:
              (task_transition_details
                 ~from_status:task.task_status
                 ~to_status:Masc_domain.Todo
                 ~reason
                 ()))
      ]
      |> List.filter_map Fun.id
    in
    Ok
      { task_id
      ; previous_status = task.task_status
      ; previous_assignee
      ; backlog_version
      ; post_commit_errors
      })
  |> Workspace_task_verification.flatten_lock_result
;;

let cancel_task_r config ~agent_name ~task_id ~reason : string Masc_domain.masc_result =
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
   Re-export the shared result type through Workspace_task. *)
type claim_next_result = Masc_domain.claim_next_result =
  | Claim_next_claimed of
      { task_id : string
      ; title : string
      ; priority : int
      ; message : string
      ; scope_widened : bool
      }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of
      { excluded_count : int
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
               ~actor_kind:Workspace_task_classify.System
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
