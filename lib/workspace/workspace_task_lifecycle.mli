(** Spec-preserving task lifecycle transition helper.

    This module centralizes the status-calculation part of
    [Workspace_task.transition_task_r]. It does not write storage, emit events,
    update agent mirrors, or change public wire semantics. *)

type drift = Claimed_to_done_skip

type invalid =
  | Self_approval
  | Self_rejection
  | Verification_disabled
  | Verification_required_use_submit
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  ; drift : drift option
  }

(** RFC-0220 §3.5: the outcome of an agent claiming a task in a given status,
    shared by the explicit and auto claim writers so they never diverge on the
    same claimable status. The self-block (a submitter cannot verify their own
    [AwaitingVerification]) lives in {!resolve_claim}, once, under one
    [same_actor] equality. *)
type claim_resolution =
  | Worker_claim of Masc_domain.task_status
  | Verifier_claim of Masc_domain.task_status
  | Self_owned
  | Held_by_other of string
  | Held_terminal of Masc_domain.task_status
      (** Terminal [Done] — never re-claimed (RFC-0323); re-running the work
          takes a NEW task linked via [predecessor_task_id]. *)

(** [resolve_claim ~same_actor ~agent_name ~now task] is the claim outcome.
    [same_actor name] must report whether [name] is the same logical actor as
    the claiming agent (callers pass
    [Workspace_task_classify.same_task_actor config _ agent_name]). *)
val resolve_claim
  :  same_actor:(string -> bool)
  -> agent_name:string
  -> now:string
  -> Masc_domain.task
  -> claim_resolution

val decide
  :  verification_enabled:bool
  -> requires_verification:bool
  -> verification_timeout_seconds:float
  -> new_verification_id:(unit -> string)
  -> same_agent:(string -> bool)
  -> agent_name:string
  -> task_id:string
  -> task_status:Masc_domain.task_status
  -> action:Masc_domain.task_action
  -> now:string
  -> authority:Masc_domain.completion_authority
  -> notes:string
  -> reason:string
  -> ?system_gate_exempt:bool
  -> (decision, invalid) result

(** Enumerate the [task_action]s that [decide] would accept for the given
    [task_status] under the supplied caller context. Pure over the [decide]
    table — useful for surfacing valid next actions to keepers before they
    dispatch a transition (closes the workaround posture noted in
    [Task.Transition_state] module header). *)
val valid_next_actions
  :  verification_enabled:bool
  -> requires_verification:bool
  -> same_agent:bool
  -> authority:Masc_domain.completion_authority
  -> task_status:Masc_domain.task_status
  -> Masc_domain.task_action list
