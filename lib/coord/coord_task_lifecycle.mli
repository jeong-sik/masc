(** Spec-preserving task lifecycle transition helper.

    This module centralizes the status-calculation part of
    [Coord_task.transition_task_r]. It does not write storage, emit events,
    update agent mirrors, or change public wire semantics. *)

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

val decide
  :  verification_enabled:bool
  -> verification_timeout_seconds:float
  -> new_verification_id:(unit -> string)
  -> agent_name:string
  -> task_id:string
  -> task_status:Types.task_status
  -> action:Types.task_action
  -> now:string
  -> force:bool
  -> notes:string
  -> reason:string
  -> (decision, invalid) result
