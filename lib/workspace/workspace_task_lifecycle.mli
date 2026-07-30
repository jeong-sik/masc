(** Pure Task lifecycle transition helper. Producers submit completion evidence
    for verification; the terminal verdict is issued by a
    [Masc_domain.completion_authority] through {!decide_verdict}, never by an
    agent action. *)

type invalid =
  | Verification_submission_required
  | Verification_not_required
      (** The task's contract did not opt into strict verification, so no
          completion authority is obligated to judge it. Submitting would move
          it into [AwaitingVerification], whose only agent-side exit is
          [Cancel] — an advisory task that submits abandons its own terminal
          [Done_action] for a verdict nobody owes it. *)
  | Verification_pending_verdict
      (** An [AwaitingVerification] obligation is not claimable by any agent. *)
  | Verdict_authority_identity_required
  | Verdict_rejection_reason_required
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  }

type claim_resolution =
  | Worker_claim of Masc_domain.task_status
  | Self_owned
  | Held_by_other of string
  | Held_terminal of Masc_domain.task_status
  | Held_pending_verdict of { verification_id : string }
      (** Awaiting a completion authority's verdict. No agent may claim it: the
          removed [Verifier_claim] made claiming the authority-granting
          operation, so a keeper became the approver by winning a race. *)

val resolve_claim
  :  same_actor:(string -> bool)
  -> agent_name:string
  -> now:string
  -> Masc_domain.task
  -> claim_resolution

val decide
  :  new_verification_id:(unit -> string)
  -> same_agent:(string -> bool)
  -> agent_name:string
  -> task_id:string
  -> task_status:Masc_domain.task_status
  -> requires_verification:bool
  -> action:Masc_domain.task_action
  -> now:string
  -> notes:string
  -> reason:string
  -> (decision, invalid) result

(** A verdict decision plus the authority provenance the caller records. The
    provenance is returned rather than embedded in [Done.notes], which is a
    human-readable field no code parses. *)
type verdict_decision =
  { decision : decision
  ; authority_kind : string
  ; authority_actor : string
  }

(** Terminal verdict on an [AwaitingVerification] obligation.

    [authority] carries provenance from a caller that authenticated an operator
    or accepted a typed judge result. The type separates verdicts from agent
    actions; it does not perform authentication itself. *)
val decide_verdict
  :  authority:Masc_domain.completion_authority
  -> verdict:Masc_domain.completion_verdict
  -> task_id:string
  -> task_status:Masc_domain.task_status
  -> now:string
  -> notes:string
  -> (verdict_decision, invalid) result

val valid_next_actions
  :  same_agent:bool
  -> task_status:Masc_domain.task_status
  -> requires_verification:bool
  -> Masc_domain.task_action list
