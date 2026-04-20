(** Spec-preserving task lifecycle transition helper. *)

type drift = Claimed_to_done_skip

type invalid =
  | Self_approval
  | Self_rejection
  | Verification_disabled
  | Invalid_transition

type decision =
  { new_status : Types.task_status
  ; set_current : string option
  ; drift : drift option
  }

let option_of_non_empty value = if String.equal value "" then None else Some value
let ok ?drift ?set_current new_status = Ok { new_status; set_current; drift }

let done_status ~agent_name ~now ~notes =
  Types.Done
    { assignee = agent_name; completed_at = now; notes = option_of_non_empty notes }
;;

let cancelled_status ~agent_name ~now ~reason =
  Types.Cancelled
    { cancelled_by = agent_name; cancelled_at = now; reason = option_of_non_empty reason }
;;

let decide
      ~verification_enabled
      ~new_verification_id
      ~agent_name
      ~task_id
      ~task_status
      ~action
      ~now
      ~force
      ~notes
      ~reason
  =
  match action, task_status with
  | Types.Claim, Types.Todo ->
    ok ~set_current:task_id (Types.Claimed { assignee = agent_name; claimed_at = now })
  | Types.Claim, (Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ })
    when String.equal assignee agent_name -> ok task_status
  | Types.Start, Types.Claimed { assignee; _ } when String.equal assignee agent_name ->
    ok ~set_current:task_id (Types.InProgress { assignee = agent_name; started_at = now })
  | Types.Start, Types.InProgress { assignee; _ } when String.equal assignee agent_name ->
    ok task_status
  | (Types.Claim | Types.Start), Types.Done _ -> ok task_status
  | Types.Done_action, Types.Claimed { assignee; _ }
    when String.equal assignee agent_name || force ->
    ok ~drift:Claimed_to_done_skip (done_status ~agent_name ~now ~notes)
  | Types.Done_action, Types.InProgress { assignee; _ }
    when String.equal assignee agent_name || force ->
    ok (done_status ~agent_name ~now ~notes)
  | Types.Done_action, Types.Done _ -> ok task_status
  | Types.Cancel, Types.Cancelled _ -> ok task_status
  | Types.Cancel, Types.Todo -> ok (cancelled_status ~agent_name ~now ~reason)
  | Types.Cancel, Types.Claimed { assignee; _ }
  | Types.Cancel, Types.InProgress { assignee; _ }
    when String.equal assignee agent_name || force ->
    ok (cancelled_status ~agent_name ~now ~reason)
  | Types.Release, Types.Claimed { assignee; _ }
  | Types.Release, Types.InProgress { assignee; _ }
    when String.equal assignee agent_name || force -> ok Types.Todo
  | Types.Release, Types.Todo -> ok task_status
  | Types.Start, Types.Claimed { assignee; _ }
    when String.equal assignee agent_name || force ->
    ok (Types.InProgress { assignee = agent_name; started_at = now })
  | Types.Submit_for_verification, Types.Claimed { assignee; _ }
  | Types.Submit_for_verification, Types.InProgress { assignee; _ }
    when String.equal assignee agent_name && verification_enabled ->
    ok
      (Types.AwaitingVerification
         { assignee
         ; submitted_at = now
         ; verification_id = new_verification_id ()
         ; required_verifier_role = Types.Reviewer
         ; deadline = None
         })
  | ( Types.Approve_verification
    , Types.AwaitingVerification { assignee; verification_id; _ } )
    when (not (String.equal agent_name assignee)) && verification_enabled ->
    ok
      (Types.Done
         { assignee
         ; completed_at = now
         ; notes =
             Some
               (Printf.sprintf
                  "Approved by %s (vrf:%s)%s"
                  agent_name
                  verification_id
                  (if String.equal notes "" then "" else " — " ^ notes))
         })
  | Types.Reject_verification, Types.AwaitingVerification { assignee; _ }
    when (not (String.equal agent_name assignee)) && verification_enabled ->
    ok (Types.InProgress { assignee; started_at = now })
  | Types.Approve_verification, Types.AwaitingVerification { assignee; _ }
    when String.equal agent_name assignee -> Error Self_approval
  | Types.Reject_verification, Types.AwaitingVerification { assignee; _ }
    when String.equal agent_name assignee -> Error Self_rejection
  | Types.Submit_for_verification, _
  | Types.Approve_verification, _
  | Types.Reject_verification, _
    when not verification_enabled -> Error Verification_disabled
  | _ -> Error Invalid_transition
;;
