(** Pure Task lifecycle transition helper. Producers submit completion evidence
    for verification; the terminal verdict is issued by a
    [Masc_domain.completion_authority] through {!decide_verdict}, never by an
    agent action. *)

type invalid =
  | Verification_submission_required
  | Verification_pending_verdict
      (** An [AwaitingVerification] obligation is not claimable by any agent. *)
  | Verdict_authority_identity_required
  | Verdict_rejection_reason_required
  | Verification_id_mismatch of { expected : string; actual : string }
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  }

let option_of_non_empty value = if String.equal value "" then None else Some value
let ok ?set_current new_status = Ok { new_status; set_current }

let done_status ~assignee ~now ~notes =
  Masc_domain.Done
    { assignee; completed_at = now; notes = option_of_non_empty notes }
;;

let cancelled_status ~agent_name ~now ~reason =
  Masc_domain.Cancelled
    { cancelled_by = agent_name; cancelled_at = now; reason = option_of_non_empty reason }
;;

type claim_resolution =
  | Worker_claim of Masc_domain.task_status
  | Self_owned
  | Held_by_other of string
  | Held_terminal of Masc_domain.task_status
  | Held_pending_verdict of { verification_id : string }

let resolve_claim ~same_actor ~agent_name ~now (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo ->
    Worker_claim (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | Masc_domain.AwaitingVerification { verification_id; _ } ->
    (* No agent claims a pending obligation. The previous behaviour bound the
       claiming agent as its verifier, which is exactly how a Keeper acquired
       approval authority: claim was the authority-granting operation. The
       verdict now comes from a [completion_authority] out of band, so the
       obligation has no assignable satisfier and no keeper is offered it. *)
    Held_pending_verdict { verification_id }
  | Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ } ->
    if same_actor assignee then Self_owned else Held_by_other assignee
  | Masc_domain.Done _ -> Held_terminal task.task_status
  | Masc_domain.Cancelled { cancelled_by; _ } -> Held_by_other cancelled_by
;;

let decide
      ~new_verification_id
      ~same_agent
      ~agent_name
      ~task_id
      ~task_status
      ~requires_verification
      ~action
      ~now
      ~notes
      ~reason
  =
  match action, task_status with
  | Masc_domain.Claim, Masc_domain.Todo ->
    ok
      ~set_current:task_id
      (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | ( Masc_domain.Claim
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee then ok task_status else Error Invalid_transition
  | Masc_domain.Claim, Masc_domain.Done _ -> ok task_status
  | Masc_domain.Claim, Masc_domain.AwaitingVerification _ ->
    (* Claiming an obligation used to bind the claimant as its verifier, so the
       claim race decided who held approval authority. There is no such binding
       now: the verdict comes from a [completion_authority] out of band. *)
    Error Verification_pending_verdict
  | Masc_domain.Claim, Masc_domain.Cancelled _ -> Error Invalid_transition
  | Masc_domain.Start, Masc_domain.Claimed { assignee; _ } ->
    if same_agent assignee
    then
      ok
        ~set_current:task_id
        (Masc_domain.InProgress { assignee; started_at = now })
    else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.InProgress { assignee; _ } ->
    if same_agent assignee then ok task_status else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Start
    , (Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _) ) ->
    Error Invalid_transition
  | ( Masc_domain.Done_action
    , ( Masc_domain.Claimed { assignee; _ }
      | Masc_domain.InProgress { assignee; _ } ) ) ->
    if not (same_agent assignee)
    then Error Invalid_transition
    else if requires_verification
    then Error Verification_submission_required
    else ok (done_status ~assignee ~now ~notes)
  | Masc_domain.Done_action, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Done_action
    , ( Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Cancelled _ ) ) ->
    Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.Cancelled _ -> ok task_status
  | Masc_domain.Cancel, Masc_domain.Todo ->
    ok (cancelled_status ~agent_name ~now ~reason)
  | ( Masc_domain.Cancel
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.AwaitingVerification { assignee; _ } ->
    if same_agent assignee
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.Done _ -> Error Invalid_transition
  | ( Masc_domain.Release
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee then ok Masc_domain.Todo else Error Invalid_transition
  | Masc_domain.Release, Masc_domain.Todo -> ok task_status
  | ( Masc_domain.Release
    , (Masc_domain.AwaitingVerification _ | Masc_domain.Done _ | Masc_domain.Cancelled _) ) ->
    Error Invalid_transition
  | ( Masc_domain.Submit_for_verification
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee
    then
      ok
        (Masc_domain.AwaitingVerification
           { assignee; submitted_at = now; verification_id = new_verification_id () })
    else Error Invalid_transition
  | ( Masc_domain.Submit_for_verification
    , ( Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ) ) ->
    Error Invalid_transition
;;

(** A verdict decision plus the typed authority provenance its caller must
    record. Keeping the sum here prevents a system-LLM or HITL authority from
    being reconstructed later from a free-form Keeper/verifier string. The
    producer and verification id come from the same awaiting snapshot. *)
type verdict_decision =
  { decision : decision
  ; authority : Masc_domain.completion_authority
  ; producer : string
  ; verification_id : string
  }

(** Terminal verdict on an [AwaitingVerification] obligation.

    Deliberately not an arm of {!decide}: a verdict is not an agent action. The
    [authority] parameter carries provenance from an authenticated operator or
    typed system-LLM judge boundary. The sum keeps verdicts out of the Keeper
    action FSM;
    authentication remains the caller's responsibility. *)
let decide_verdict
      ~(authority : Masc_domain.completion_authority)
      ~(verdict : Masc_domain.completion_verdict)
      ~task_id
      ~verification_id:expected_verification_id
      ~(task_status : Masc_domain.task_status)
      ~now
      ~notes
  =
  let provenance ~producer ~verification_id decision =
    if not (Masc_domain.completion_authority_has_identity authority)
    then Error Verdict_authority_identity_required
    else
      Ok
        { decision
        ; authority
        ; producer
        ; verification_id
        }
  in
  match task_status with
  | Masc_domain.AwaitingVerification
      { assignee; verification_id = actual_verification_id; _ } ->
    if not (String.equal expected_verification_id actual_verification_id)
    then
      Error
        (Verification_id_mismatch
           { expected = expected_verification_id; actual = actual_verification_id })
    else
      (match verdict with
       | Masc_domain.Verdict_approved ->
         provenance
           ~producer:assignee
           ~verification_id:actual_verification_id
           { new_status = done_status ~assignee ~now ~notes; set_current = None }
       | Masc_domain.Verdict_rejected { reason } ->
         if String.equal (String.trim reason) ""
         then Error Verdict_rejection_reason_required
         else
           provenance
             ~producer:assignee
             ~verification_id:actual_verification_id
             { new_status = Masc_domain.InProgress { assignee; started_at = now }
             ; set_current = Some task_id
             })
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> Error Invalid_transition
;;

let valid_next_actions ~same_agent ~task_status ~requires_verification =
  let same_agent_pred _ = same_agent in
  let try_action action =
    match
      decide
        ~new_verification_id:(fun () -> "")
        ~same_agent:same_agent_pred
        ~agent_name:""
        ~task_id:""
        ~task_status
        ~requires_verification
        ~action
        ~now:""
        ~notes:"preview"
        ~reason:"preview"
    with
    | Ok _ -> true
    | Error _ -> false
  in
  List.filter try_action Masc_domain.all_task_actions
;;
