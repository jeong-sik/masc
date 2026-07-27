(** Pure Task lifecycle transition helper. Producers submit completion evidence
    for verification; the phase-assigned verifier owns the terminal verdict. *)

type invalid =
  | Verification_submission_required
  | Verification_claim_required
  | Verification_assigned_to of string
  | Verification_self_claim
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  }

type claim_resolution =
  | Worker_claim of Masc_domain.task_status
  | Verifier_claim of Masc_domain.task_status
  | Self_owned
  | Self_verification
  | Held_by_other of string
  | Held_terminal of Masc_domain.task_status

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

val valid_next_actions
  :  same_agent:bool
  -> task_status:Masc_domain.task_status
  -> requires_verification:bool
  -> Masc_domain.task_action list
