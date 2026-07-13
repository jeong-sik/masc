(** Pure Task lifecycle transition helper. Semantic completion is authorized by
    a request-local configured-LLM verdict, never by an actor hierarchy. *)

type invalid =
  | Completion_verdict_required
  | Completion_rejected of string
  | Completion_verdict_unavailable of string
  | Completion_verdict_action_mismatch
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  }

type claim_resolution =
  | Worker_claim of Masc_domain.task_status
  | Verifier_claim of Masc_domain.task_status
  | Self_owned
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
  -> action:Masc_domain.task_action
  -> now:string
  -> configured_llm_verdict:Masc_domain.configured_llm_completion_verdict option
  -> notes:string
  -> reason:string
  -> (decision, invalid) result

val valid_next_actions
  :  same_agent:bool
  -> task_status:Masc_domain.task_status
  -> Masc_domain.task_action list
