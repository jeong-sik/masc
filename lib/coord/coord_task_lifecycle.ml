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

let verification_deadline ~now ~timeout_seconds =
  let submitted_at = Types.parse_iso8601 ~default_time:(Time_compat.now ()) now in
  Some (Types.iso8601_of_unix_seconds (submitted_at +. timeout_seconds))
;;

let decide
      ~verification_enabled
      ~verification_timeout_seconds
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
  let same_agent assignee = String.equal assignee agent_name in
  match action, task_status with
  (* ── Claim ────────────────────────────────────── *)
  | Types.Claim, Types.Todo ->
    ok ~set_current:task_id (Types.Claimed { assignee = agent_name; claimed_at = now })
  | Types.Claim, (Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ }) ->
    if same_agent assignee then ok task_status
    else Error Invalid_transition
  | Types.Claim, Types.Done _ ->
    ok task_status
  | Types.Claim, (Types.AwaitingVerification _ | Types.Cancelled _) ->
    Error Invalid_transition
  (* ── Start ────────────────────────────────────── *)
  | Types.Start, Types.Claimed { assignee; _ } ->
    if same_agent assignee || force
    then ok ~set_current:task_id
           (Types.InProgress { assignee = agent_name; started_at = now })
    else Error Invalid_transition
  | Types.Start, Types.InProgress { assignee; _ } ->
    if same_agent assignee then ok task_status
    else Error Invalid_transition
  | Types.Start, Types.Done _ ->
    ok task_status
  | Types.Start, (Types.Todo | Types.AwaitingVerification _ | Types.Cancelled _) ->
    Error Invalid_transition
  (* ── Done ─────────────────────────────────────── *)
  | Types.Done_action, Types.Claimed { assignee; _ } ->
    if same_agent assignee || force
    then ok ~drift:Claimed_to_done_skip (done_status ~agent_name ~now ~notes)
    else Error Invalid_transition
  | Types.Done_action, Types.InProgress { assignee; _ } ->
    if same_agent assignee || force
    then ok (done_status ~agent_name ~now ~notes)
    else Error Invalid_transition
  | Types.Done_action, Types.Done _ ->
    ok task_status
  | Types.Done_action, (Types.Todo | Types.AwaitingVerification _ | Types.Cancelled _) ->
    Error Invalid_transition
  (* ── Cancel ───────────────────────────────────── *)
  | Types.Cancel, Types.Cancelled _ ->
    ok task_status
  | Types.Cancel, Types.Todo ->
    ok (cancelled_status ~agent_name ~now ~reason)
  | Types.Cancel, (Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ }) ->
    if same_agent assignee || force
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Types.Cancel, Types.AwaitingVerification _ ->
    if force
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Types.Cancel, Types.Done _ ->
    Error Invalid_transition
  (* ── Release ──────────────────────────────────── *)
  | Types.Release, (Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ }) ->
    if same_agent assignee || force then ok Types.Todo
    else Error Invalid_transition
  | Types.Release, Types.Todo ->
    ok task_status
  | Types.Release, (Types.AwaitingVerification _ | Types.Done _ | Types.Cancelled _) ->
    Error Invalid_transition
  (* ── Submit for verification ──────────────────── *)
  | Types.Submit_for_verification,
    (Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ }) ->
    if not verification_enabled then Error Verification_disabled
    else if same_agent assignee
    then ok
           (Types.AwaitingVerification
              { assignee
              ; submitted_at = now
              ; verification_id = new_verification_id ()
              ; deadline =
                  verification_deadline
                    ~now
                    ~timeout_seconds:verification_timeout_seconds
              })
    else Error Invalid_transition
  | Types.Submit_for_verification,
    (Types.Todo | Types.AwaitingVerification _ | Types.Done _ | Types.Cancelled _) ->
    if verification_enabled then Error Invalid_transition
    else Error Verification_disabled
  (* ── Approve verification ─────────────────────── *)
  | Types.Approve_verification,
    Types.AwaitingVerification { assignee; verification_id; _ } ->
    if same_agent assignee then Error Self_approval
    else if verification_enabled
    then ok
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
    else Error Verification_disabled
  | Types.Approve_verification,
    (Types.Todo | Types.Claimed _ | Types.InProgress _ | Types.Done _ | Types.Cancelled _) ->
    if verification_enabled then Error Invalid_transition
    else Error Verification_disabled
  (* ── Reject verification ──────────────────────── *)
  | Types.Reject_verification,
    Types.AwaitingVerification { assignee; _ } ->
    if same_agent assignee then Error Self_rejection
    else if verification_enabled
    then ok (Types.InProgress { assignee; started_at = now })
    else Error Verification_disabled
  | Types.Reject_verification,
    (Types.Todo | Types.Claimed _ | Types.InProgress _ | Types.Done _ | Types.Cancelled _) ->
    if verification_enabled then Error Invalid_transition
    else Error Verification_disabled
;;
