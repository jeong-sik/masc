(** Contract-violation retry helper, extracted from [Keeper_agent_run]. *)

let retry_feedback_message text : Agent_sdk.Types.message =
  { Agent_sdk.Types.role = User
  ; content = [ Agent_sdk.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let satisfying_tools_for_violation ~acc ~has_current_task ~turn_affordances
    ~violation_reason ~violation_detail =
  let local_tools =
    Keeper_agent_tool_surface.generic_required_tool_candidate_names
      ~has_current_task
      ~turn_affordances
      ~allowed_tool_names:acc.Keeper_run_tools.tool_surface.required_tool_candidate_names
  in
  let oas_tools =
    match violation_detail with
    | Some detail when detail.Agent_sdk.Completion_contract_violation_detail.satisfying_tools <> []
      ->
      detail.satisfying_tools
    | Some _ | None ->
      Keeper_tool_disclosure.satisfying_tools_from_contract_violation_reason
        violation_reason
  in
  Keeper_types.dedupe_keep_order (oas_tools @ local_tools)
;;

let retry_action = function
  | [] ->
    "No currently visible tool can satisfy this contract; emit a concise blocker instead."
  | tools -> Printf.sprintf "You MUST call one of these tools: %s." (String.concat ", " tools)
;;

let retry_feedback ~violation_reason ~satisfying_tools =
  Printf.sprintf
    "[CONTRACT VIOLATION] Your previous response was rejected: %s. %s Do NOT respond with text only."
    violation_reason
    (retry_action satisfying_tools)
;;

let run_with_single_retry ~keeper_name ~acc ~has_current_task ~turn_affordances
    ~history_messages ~call_run_named =
  match call_run_named ~initial_messages:history_messages with
  | Error
      (Agent_sdk.Error.Agent
         (Agent_sdk.Error.CompletionContractViolation
            { reason = violation_reason; violation_detail; _ }))
    when acc.Keeper_run_tools.contract_violation_retries < 1 ->
    (* Contract violation retry (max 1 per turn): the model did not call a
       required tool. Re-run with feedback so the model sees why it was
       rejected. The context builder in [Keeper_run_tools] injects extra
       guidance because [contract_violation_retries > 0]. *)
    acc.contract_violation_retries <- acc.contract_violation_retries + 1;
    let satisfying_tools =
      satisfying_tools_for_violation
        ~acc
        ~has_current_task
        ~turn_affordances
        ~violation_reason
        ~violation_detail
    in
    let retry_feedback = retry_feedback ~violation_reason ~satisfying_tools in
    let retry_messages = history_messages @ [ retry_feedback_message retry_feedback ] in
    Log.Keeper.info
      "keeper:%s contract violation retry #%d (reason: %s)"
      keeper_name
      acc.contract_violation_retries
      violation_reason;
    call_run_named ~initial_messages:retry_messages
  | other -> other
;;
