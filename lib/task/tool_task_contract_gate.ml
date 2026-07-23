(** Tool_task_contract_gate — task lifecycle invariants unrelated to
    completion-quality judgment.

    @since God file decomposition — extracted from tool_task.ml *)

let strict_release_requires_handoff = function
  | Some ({ contract = Some contract; _ } : Masc_domain.task) -> contract.strict
  | _ -> false

let completion_state_error ~(task_id : string) ~(agent_name : string)
    ~(task_opt : Masc_domain.task option) =
  match task_opt with
  | None -> Some (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
  | Some task ->
    match task.task_status with
    | Masc_domain.InProgress { assignee; _ } ->
      if String.equal assignee agent_name then
        None
      else
        Some (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed { task_id; by = assignee }))
    | Masc_domain.Claimed { assignee; _ } ->
      if String.equal assignee agent_name
      then None
      else
        Some
          (Masc_domain.Task
             (Masc_domain.Task_error.AlreadyClaimed { task_id; by = assignee }))
    | Masc_domain.Todo -> Some (Masc_domain.Task (Masc_domain.Task_error.NotClaimed task_id))
    | Masc_domain.Done { assignee; _ } ->
      Some
        (Masc_domain.Task (Masc_domain.Task_error.InvalidState
           (Printf.sprintf
              "task %s is already done by %s; inspect task history instead of calling masc_transition(action=done) again"
              task_id assignee)))
    | Masc_domain.Cancelled { cancelled_by; _ } ->
      Some
        (Masc_domain.Task (Masc_domain.Task_error.InvalidState
           (Printf.sprintf
              "task %s was cancelled by %s; reopen or create a new task instead of calling masc_transition(action=done)"
              task_id cancelled_by)))
    | Masc_domain.AwaitingVerification { assignee; _ } ->
      Some
        (Masc_domain.Task (Masc_domain.Task_error.InvalidState
           (Printf.sprintf
              "task %s has a pending verification workflow for %s; resolve it before marking done"
              task_id assignee)))
