(** Workspace_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next.

    Facade module: includes Workspace_task_transitions (which includes classify,
    create, claim sub-modules). *)

open Masc_domain
open Workspace_backlog

include Workspace_task_transitions

(** Delete one Task under the canonical backlog lock and clear any agent cache
    that still points at it in the same commit boundary. *)
let delete_task_r config ~task_id : unit Masc_domain.masc_result =
  with_file_lock_r config (backlog_lock_path config) (fun () ->
    let open Result.Syntax in
    let* backlog =
      read_backlog_r config
      |> Result.map_error (fun message ->
        Masc_domain.System (Masc_domain.System_error.IoError message))
    in
    let task_opt =
      List.find_opt (fun (task : task) -> String.equal task.id task_id) backlog.tasks
    in
    let tasks =
      List.filter (fun (task : task) -> not (String.equal task.id task_id)) backlog.tasks
    in
    let status =
      match task_opt with
      | Some task -> task.task_status
      | None -> Masc_domain.Todo
    in
    let after_commit () =
      Task_cache_invariant.clear_stale_agent_task_for_task
        config
        ~cause:Task_cache_invariant.After_commit
        ~task_id
        ~status
        ~module_name:"workspace_task.delete_task_r"
    in
    write_backlog ~after_commit config { backlog with tasks };
    Ok ())
  |> Workspace_task_verification.flatten_lock_result
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
  let lock_path = backlog_lock_path config in
  with_file_lock_r config lock_path (fun () ->
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
    let* persistence =
      write_backlog_result
        config
        { backlog with tasks }
      |> Result.map_error (fun message ->
        Masc_domain.System (Masc_domain.System_error.IoError message))
    in
    let backlog_version = persistence.committed_revision in
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
            ~cause:Task_cache_invariant.After_commit
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
    let lock_path = backlog_lock_path config in
    let result =
      with_file_lock_r config lock_path (fun () ->
      try
        match read_backlog_r config with
        | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
        | Ok backlog ->
          (match List.find_opt (fun (task : task) -> task.id = task_id) backlog.tasks with
           | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
           | Some task ->
             (* Only execution identity moves here. The contract is whatever the
                task was created with, including absent. *)
             let updated_links =
               merge_execution_links
                 task.execution_links
                 ?session_id
                 ?operation_id
                 ()
             in
             let new_tasks =
               List.map
                 (fun (candidate : task) ->
                    if candidate.id = task_id
                    then { candidate with execution_links = updated_links }
                    else candidate)
                 backlog.tasks
             in
             (* [write_backlog] stamps version/last_updated at the commit
                point. *)
             let new_backlog = { backlog with tasks = new_tasks } in
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
