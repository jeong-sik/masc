type invalid =
  | Verification_submission_required
  | Verification_pending_verdict
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
  match Masc_domain.task_claim_decision_for_status task.task_status with
  | Masc_domain.Claim_available Masc_domain.Claim_ready ->
    Worker_claim (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | Masc_domain.Claim_unavailable
      (Masc_domain.Claim_block_pending_verdict { verification_id }) ->
    Held_pending_verdict { verification_id }
  | Masc_domain.Claim_unavailable (Masc_domain.Claim_block_not_todo task_status) ->
    (match task_status with
     | Masc_domain.Claimed { assignee; _ }
     | Masc_domain.InProgress { assignee; _ } ->
       if same_actor assignee then Self_owned else Held_by_other assignee
     | Masc_domain.Done _ -> Held_terminal task_status
     | Masc_domain.Cancelled { cancelled_by; _ } -> Held_by_other cancelled_by
     | Masc_domain.Todo | Masc_domain.AwaitingVerification _ ->
       (* These constructors are not produced by the status-level decision for
          this branch. Keep the match exhaustive so a future status addition
          cannot silently widen claim admission. *)
       Held_terminal task_status)
;;

let decide
      ~new_verification_id
      ~same_agent
      ~agent_name
      ~task_id
      ~task_status
      ~action
      ~now
      ~notes
      ~reason
  =
  match action, task_status with
  | Masc_domain.Claim, task_status ->
    (match Masc_domain.task_claim_decision_for_status task_status with
     | Masc_domain.Claim_available Masc_domain.Claim_ready ->
       ok
         ~set_current:task_id
         (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
     | Masc_domain.Claim_unavailable
         (Masc_domain.Claim_block_pending_verdict _) ->
       Error Verification_pending_verdict
     | Masc_domain.Claim_unavailable
         (Masc_domain.Claim_block_not_todo status) ->
       (match status with
        | Masc_domain.Claimed { assignee; _ }
        | Masc_domain.InProgress { assignee; _ } ->
          if same_agent assignee then ok status else Error Invalid_transition
        | Masc_domain.Done _ -> ok status
        | Masc_domain.Cancelled _ -> Error Invalid_transition
        | Masc_domain.Todo | Masc_domain.AwaitingVerification _ ->
          Error Invalid_transition))
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
    else Error Verification_submission_required
  | Masc_domain.Done_action, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Done_action
    , ( Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Cancelled _ ) ) ->
    Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.Cancelled _ -> ok task_status
  | Masc_domain.Cancel, Masc_domain.Todo ->
    ok (cancelled_status ~agent_name ~now ~reason)
  (* A producer stops its own work the same way it finishes it: by submitting
     the claim and waiting for a verdict. Cancelling outright would give a
     Keeper one terminal state it can reach alone while [Done_action] refuses
     every lane that is not a submission — "I could not do this" would settle
     itself and "I did this" would not. *)
  | ( Masc_domain.Cancel
    , Masc_domain.Claimed { assignee; claimed_at = started_at } )
  | ( Masc_domain.Cancel
    , Masc_domain.InProgress { assignee; started_at } ) ->
    if same_agent assignee
    then
      ok
        (Masc_domain.AwaitingVerification
           { assignee
           ; started_at
           ; submitted_at = now
           ; intent = Masc_domain.Cancel_task
           ; verification_id = new_verification_id ()
           })
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
    , Masc_domain.Claimed { assignee; claimed_at } ) ->
    if same_agent assignee
    then
      ok
        (Masc_domain.AwaitingVerification
           { assignee
           ; started_at = claimed_at
           ; submitted_at = now
           ; intent = Masc_domain.Complete_task
           ; verification_id = new_verification_id ()
           })
    else Error Invalid_transition
  | ( Masc_domain.Submit_for_verification
    , Masc_domain.InProgress { assignee; started_at } ) ->
    if same_agent assignee
    then
      ok
        (Masc_domain.AwaitingVerification
           { assignee
           ; started_at
           ; submitted_at = now
           ; intent = Masc_domain.Complete_task
           ; verification_id = new_verification_id ()
           })
    else Error Invalid_transition
  (* Resubmission supersedes the pending obligation instead of replacing the
     task. Refusing it left [Cancel] as the assignee's only move out of
     [AwaitingVerification], and the live backlog shows what that cost: 16
     refusals of this exact transition, and 10 cancellations whose stated reason
     was the deliverable itself.

     A fresh [verification_id] is what makes it safe. A verdict computed against
     the superseded request carries the old id and is refused by
     {!decide_verdict} with [Verification_id_mismatch], so an in-flight judge
     cannot land on evidence it never read. [started_at] is preserved: the work
     began once, whatever the submission count. *)
  | ( Masc_domain.Submit_for_verification
    , Masc_domain.AwaitingVerification { assignee; started_at; _ } ) ->
    if same_agent assignee
    then
      ok
        (Masc_domain.AwaitingVerification
           { assignee
           ; started_at
           ; submitted_at = now
           ; intent = Masc_domain.Complete_task
           ; verification_id = new_verification_id ()
           })
    else Error Invalid_transition
  | ( Masc_domain.Submit_for_verification
    , (Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _) ) ->
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
      { assignee; started_at; intent; verification_id = actual_verification_id; _ } ->
    if not (String.equal expected_verification_id actual_verification_id)
    then
      Error
        (Verification_id_mismatch
           { expected = expected_verification_id; actual = actual_verification_id })
    else
      (match verdict with
       (* One verdict, two terminals. The obligation records which question
          was asked, so an approval ends the Task the way the producer asked
          rather than the way this branch used to assume. *)
       | Masc_domain.Verdict_approved ->
         let new_status =
           match intent with
           | Masc_domain.Complete_task -> done_status ~assignee ~now ~notes
           | Masc_domain.Cancel_task ->
             cancelled_status ~agent_name:assignee ~now ~reason:notes
         in
         provenance
           ~producer:assignee
           ~verification_id:actual_verification_id
           { new_status; set_current = None }
       | Masc_domain.Verdict_rejected { reason } ->
         if String.equal (String.trim reason) ""
         then Error Verdict_rejection_reason_required
         else
           provenance
             ~producer:assignee
             ~verification_id:actual_verification_id
             { new_status = Masc_domain.InProgress { assignee; started_at }
             ; set_current = Some task_id
             })
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> Error Invalid_transition
;;

let valid_next_actions ~same_agent ~task_status =
  let same_agent_pred _ = same_agent in
  let try_action action =
    match
      decide
        ~new_verification_id:(fun () -> "")
        ~same_agent:same_agent_pred
        ~agent_name:""
        ~task_id:""
        ~task_status
        ~action
        ~now:""
        ~notes:"preview"
        ~reason:"preview"
    with
    (* An action the FSM admits but that leaves the status where it is -- Claim
       on a Task you already hold, Start on one already started, Release on a
       Todo, Cancel on a Cancelled one -- is not a next action. It is accepted
       so a repeat is idempotent rather than an error, which is a different
       question from "what can you do from here".

       Listing them told a Keeper that a Done Task's next actions were
       [claim;start;done], all three of which return it unchanged. The Goal
       surface answers the same question the same way as of #27464: its
       available-actions list carries [Move_to] and drops [Already]. *)
    | Ok { new_status; _ } -> new_status <> task_status
    | Error _ -> false
  in
  List.filter try_action Masc_domain.all_task_actions
;;
