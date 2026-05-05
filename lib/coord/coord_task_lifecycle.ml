(** Spec-preserving task lifecycle transition helper. *)

type drift = Claimed_to_done_skip

type invalid =
  | Self_approval
  | Self_rejection
  | Verification_disabled
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  ; drift : drift option
  }

let option_of_non_empty value = if String.equal value "" then None else Some value
let ok ?drift ?set_current new_status = Ok { new_status; set_current; drift }

let done_status ~agent_name ~now ~notes =
  Masc_domain.Done
    { assignee = agent_name; completed_at = now; notes = option_of_non_empty notes }
;;

let cancelled_status ~agent_name ~now ~reason =
  Masc_domain.Cancelled
    { cancelled_by = agent_name; cancelled_at = now; reason = option_of_non_empty reason }
;;

let verification_deadline ~now ~timeout_seconds =
  let submitted_at = Masc_domain.parse_iso8601 ~default_time:(Time_compat.now ()) now in
  Some (Masc_domain.iso8601_of_unix_seconds (submitted_at +. timeout_seconds))
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
  | Masc_domain.Claim, Masc_domain.Todo ->
    ok ~set_current:task_id (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | Masc_domain.Claim, (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ->
    if same_agent assignee then ok task_status
    else Error Invalid_transition
  | Masc_domain.Claim, Masc_domain.Done _ ->
    ok task_status
  | Masc_domain.Claim, (Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _) ->
    Error Invalid_transition
  (* ── Start ────────────────────────────────────── *)
  | Masc_domain.Start, Masc_domain.Claimed { assignee; _ } ->
    if same_agent assignee || force
    then ok ~set_current:task_id
           (Masc_domain.InProgress { assignee = agent_name; started_at = now })
    else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.InProgress { assignee; _ } ->
    if same_agent assignee then ok task_status
    else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.Done _ ->
    ok task_status
  | Masc_domain.Start, (Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _) ->
    Error Invalid_transition
  (* ── Done ─────────────────────────────────────── *)
  | Masc_domain.Done_action, Masc_domain.Claimed { assignee; _ } ->
    if same_agent assignee || force
    then ok ~drift:Claimed_to_done_skip (done_status ~agent_name ~now ~notes)
    else Error Invalid_transition
  | Masc_domain.Done_action, Masc_domain.InProgress { assignee; _ } ->
    if same_agent assignee || force
    then ok (done_status ~agent_name ~now ~notes)
    else Error Invalid_transition
  | Masc_domain.Done_action, Masc_domain.Done _ ->
    ok task_status
  | Masc_domain.Done_action, (Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _) ->
    Error Invalid_transition
  (* ── Cancel ───────────────────────────────────── *)
  | Masc_domain.Cancel, Masc_domain.Cancelled _ ->
    ok task_status
  | Masc_domain.Cancel, Masc_domain.Todo ->
    ok (cancelled_status ~agent_name ~now ~reason)
  | Masc_domain.Cancel, (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ->
    if same_agent assignee || force
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.AwaitingVerification _ ->
    if force
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.Done _ ->
    Error Invalid_transition
  (* ── Release ──────────────────────────────────── *)
  | Masc_domain.Release, (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ->
    if same_agent assignee || force then ok Masc_domain.Todo
    else Error Invalid_transition
  | Masc_domain.Release, Masc_domain.Todo ->
    ok task_status
  | Masc_domain.Release, (Masc_domain.AwaitingVerification _ | Masc_domain.Done _ | Masc_domain.Cancelled _) ->
    Error Invalid_transition
  (* ── Submit for verification ──────────────────── *)
  | Masc_domain.Submit_for_verification,
    (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ->
    if not verification_enabled then Error Verification_disabled
    else if same_agent assignee
    then ok
           (Masc_domain.AwaitingVerification
              { assignee
              ; submitted_at = now
              ; verification_id = new_verification_id ()
              ; deadline =
                  verification_deadline
                    ~now
                    ~timeout_seconds:verification_timeout_seconds
              })
    else Error Invalid_transition
  | Masc_domain.Submit_for_verification,
    (Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Done _ | Masc_domain.Cancelled _) ->
    if verification_enabled then Error Invalid_transition
    else Error Verification_disabled
  (* ── Approve verification ─────────────────────── *)
  | Masc_domain.Approve_verification,
    Masc_domain.AwaitingVerification { assignee; verification_id; _ } ->
    if same_agent assignee then Error Self_approval
    else if verification_enabled
    then ok
           (Masc_domain.Done
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
  | Masc_domain.Approve_verification,
    (Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.Done _ | Masc_domain.Cancelled _) ->
    if verification_enabled then Error Invalid_transition
    else Error Verification_disabled
  (* ── Reject verification ──────────────────────── *)
  | Masc_domain.Reject_verification,
    Masc_domain.AwaitingVerification { assignee; _ } ->
    if same_agent assignee then Error Self_rejection
    else if verification_enabled
    then ok (Masc_domain.InProgress { assignee; started_at = now })
    else Error Verification_disabled
  | Masc_domain.Reject_verification,
    (Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.Done _ | Masc_domain.Cancelled _) ->
    if verification_enabled then Error Invalid_transition
    else Error Verification_disabled
;;
