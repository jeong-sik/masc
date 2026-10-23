let owner_rule_id = function
  | Masc_domain.Release -> "task_release_requires_current_owner"
  | Masc_domain.Submit_for_verification -> "task_submit_requires_current_owner"
  | Masc_domain.Done_action -> "task_done_requires_current_owner"
  | Masc_domain.Claim | Masc_domain.Start | Masc_domain.Cancel ->
    "task_transition_requires_current_owner"

let payload (rejection : Masc_domain.Task_error.transition_rejected) =
  let rule_id, recoverable, owner_fields =
    match rejection.reason with
    | Masc_domain.Task_error.Current_owner_required { current_assignee } ->
      owner_rule_id rejection.action, None,
      [ "current_assignee", `String current_assignee ]
    | Masc_domain.Task_error.Claim_required ->
      "task_submit_requires_claimed_or_started", Some true, []
  in
  Workflow_rejection_payload.payload
    ~rule_id ?recoverable
    ~extra_fields:
      ([ "task_id", `String rejection.task_id
       ; "task_status", `String (Masc_domain.task_status_to_string rejection.task_status)
       ; "action", `String (Masc_domain.task_action_to_string rejection.action)
       ; "requested_agent", `String rejection.requested_agent
       ; "valid_next_actions",
         `List
           (List.map
              (fun action -> `String (Masc_domain.task_action_to_string action))
              rejection.valid_next_actions)
       ] @ owner_fields)
    (Masc_domain.Task_error.transition_rejection_message rejection)
