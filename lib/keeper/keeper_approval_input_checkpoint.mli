(** Durable approval-input admission before model dispatch. No operation or
    queue is completed here. Fresh canonical history is the CAS source. *)
val admit : ?co_inputs:(Keeper_approval_input_admission.identity * Agent_core.Types.message) list ->
  session_dir:string -> identity:Keeper_approval_input_admission.identity ->
  message:Agent_core.Types.message -> Agent_core.Checkpoint.t ->
  (Agent_core.Checkpoint.t, string) result

val admit_to_destination : ?co_inputs:(Keeper_approval_input_admission.identity * Agent_core.Types.message) list ->
  destination:Keeper_checkpoint_destination.t -> session_dir:string ->
  identity:Keeper_approval_input_admission.identity -> message:Agent_core.Types.message ->
  Agent_core.Checkpoint.t -> (Agent_core.Checkpoint.t, string) result
(** Canonical admission retains its existing fresh-source CAS. Operation
    admission uses only this dispatch's confirmed retained payload and original
    child, preserving independent global history and pending input. *)
