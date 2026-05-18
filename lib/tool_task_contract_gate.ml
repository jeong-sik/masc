(** Tool_task_contract_gate — task-contract predicates and CDAL gate
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

let task_requires_verification = function
  | Some ({ contract = Some contract; _ } : Masc_domain.task) ->
    contract_requires_verification contract
  | _ -> false

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

let persisted_contract_rejection ~(agent_name : string)
    ~(task_opt : Masc_domain.task option) ~(notes : string) =
  ignore notes;
  match task_opt with
  | None -> None
  | Some task ->
    if not (Env_config_runtime.Cdal.gate_enabled ()) then begin
      Log.Task.info "[cdal-gate] disabled, skipping for task=%s agent=%s"
        task.id agent_name;
      None
    end else
      match task.contract with
      | None -> None
      | Some contract ->
        (* Always run the verdict lookup so Dashboard_attribution records the
           outcome (pass / policy_failed / missing). strict=false stays
           advisory — we drop the rejection but keep the audit trail so the
           dashboard shows a verification trace instead of nothing.

           Advisory recordings go into the [cdal_verdict_advisory] gate
           bucket so the dashboard can distinguish "strict-enforced"
           from "allowed through under advisory" without guessing. *)
        let gate_label =
          if contract.strict then Cdal_verdict_gate.strict_gate_label
          else Cdal_verdict_gate.advisory_gate_label
        in
        Log.Task.info
          "[cdal-gate] checking verdict for task=%s agent=%s strict=%b gate=%s"
          task.id agent_name contract.strict gate_label;
        let rejection =
          Cdal_verdict_gate.gate_check ~gate_label ~task_id:task.id ()
        in
        if contract.strict then rejection
        else begin
          (match rejection with
           | Some msg ->
             Log.Task.info
               "[cdal-gate] advisory (strict=false) for task=%s: %s"
               task.id msg
           | None -> ());
          None
        end

let cdal_gate_label_for_task = function
  | Some ({ contract = Some { strict = false; _ }; _ } : Masc_domain.task) ->
    Cdal_verdict_gate.advisory_gate_label
  | _ -> Cdal_verdict_gate.strict_gate_label
