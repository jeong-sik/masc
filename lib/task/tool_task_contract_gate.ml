(** Tool_task_contract_gate — task-contract predicates and verification gate
    evaluation for task tools.

    Contract predicates ([task_has_persisted_contract] etc.) are pure
    and [context]-free. [persisted_contract_rejection] performs a
    side-effecting gate lookup ({!Cdal_verdict_gate.gate_check}) plus
    structured logging; it takes [~agent_name] explicitly so it does
    not depend on the {!Tool_task} [context] type.

    @since God file decomposition — extracted from tool_task.ml *)

let task_has_persisted_contract = function
  | Some (task : Masc_domain.task) -> Option.is_some task.contract
  | None -> false

let task_has_strict_persisted_contract = function
  | Some ({ contract = Some { strict = true; _ }; _ } : Masc_domain.task) ->
    true
  | _ -> false

let contract_requires_verification (contract : Masc_domain.task_contract) =
  Stdlib.List.length contract.completion_contract > 0
  || Stdlib.List.length contract.required_evidence > 0
  || Stdlib.List.length contract.verify_gate_evidence > 0

(* RFC-0323 G-1: delegates to the FSM-layer predicate now wired into
   [Workspace_task_lifecycle.decide]. NOT [contract_requires_verification]:
   creation auto-fills an advisory contract for every task, so
   contract-presence is vacuously true fleet-wide — [strict] is the
   explicit opt-in (Phase A). *)
let task_requires_verification = function
  | Some (task : Masc_domain.task) -> Masc_domain.task_requires_verification task
  | None -> false

let strict_release_requires_handoff = function
  | Some ({ contract = Some contract; _ } : Masc_domain.task) -> contract.strict
  | _ -> false

let completion_state_error ~(task_id : string) ~(agent_name : string)
    ~(task_opt : Masc_domain.task option) =
  match task_opt with
  | None -> Some (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
  | Some task ->
    match task.task_status with
    | Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ } ->
      if String.equal assignee agent_name then
        None
      else
        Some (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed { task_id; by = assignee }))
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
              "task %s is awaiting verification by %s; approve or reject before marking done"
              task_id assignee)))
    | Masc_domain.Operator_blocked _ ->
      Some
        (Masc_domain.Task (Masc_domain.Task_error.InvalidState
           (Printf.sprintf
              "task %s is operator-blocked; unblock before marking done" task_id)))

(* Verification is owned solely by [Task_completion_gate], applied upstream in
   [Tool_task.handle_transition]. This per-action layer formerly ran a second
   gate against the contract-verdict ledger; that ledger no longer exists, so this
   layer never rejects. Kept as a typed seam so the transition control flow is
   unchanged. *)
let persisted_contract_rejection ~(agent_name : string)
    ~(task_opt : Masc_domain.task option) ~(notes : string) : string option =
  ignore agent_name;
  ignore task_opt;
  ignore notes;
  None
