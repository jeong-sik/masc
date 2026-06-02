(** Contract-violation retry helper, extracted from [Keeper_agent_run]. *)

let retry_feedback_message text : Agent_sdk.Types.message =
  { Agent_sdk.Types.role = User
  ; content = [ Agent_sdk.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let retry_feedback ~violation_reason =
  Printf.sprintf
    "[CONTRACT VIOLATION] Your previous response was rejected: %s. Call a visible keeper tool. Do NOT respond with text only."
    violation_reason
;;

(* KeeperContractViolated.tla: a detected completion-contract violation must
   feed an explicit correction back into the retry turn. *)
let post_contract_violation_retry_feedback
      ~(history_message_count : int)
      ~(retry_message_count : int)
      ~(retry_count : int)
      ~(feedback_text : string)
  =
  ignore history_message_count;
  ignore retry_message_count;
  ignore retry_count;
  ignore feedback_text
[@@fsm_guard
  "retry_count > 0 && retry_message_count = history_message_count + 1 && String_util.contains_substring_ci feedback_text \"contract violation\""]
;;

let run_with_single_retry ~keeper_name ~acc
    ~history_messages ~call_run_named =
  match call_run_named ~initial_messages:history_messages with
  | Error
      (Agent_sdk.Error.Agent
         (Agent_sdk.Error.CompletionContractViolation
            { reason = violation_reason; _ }))
    when acc.Keeper_run_tools.contract_violation_retries < 1 ->
    (* Contract violation retry (max 1 per turn): the model did not call a
       required tool. Re-run with feedback so the model sees why it was
       rejected. The context builder in [Keeper_run_tools] injects extra
       guidance because [contract_violation_retries > 0]. *)
    acc.contract_violation_retries <- acc.contract_violation_retries + 1;
    let retry_feedback = retry_feedback ~violation_reason in
    let retry_messages = history_messages @ [ retry_feedback_message retry_feedback ] in
    post_contract_violation_retry_feedback
      ~history_message_count:(List.length history_messages)
      ~retry_message_count:(List.length retry_messages)
      ~retry_count:acc.contract_violation_retries
      ~feedback_text:retry_feedback;
    Log.Keeper.info
      "keeper:%s contract violation retry #%d (reason: %s)"
      keeper_name
      acc.contract_violation_retries
      violation_reason;
    call_run_named ~initial_messages:retry_messages
  | other -> other
;;
