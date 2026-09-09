(** Durable approval-input admission before model dispatch. No operation or
    queue is completed here. Fresh canonical history is the CAS source. *)
val admit : session_dir:string -> identity:Keeper_approval_input_admission.identity ->
  message:Agent_core.Types.message -> Agent_core.Checkpoint.t ->
  (Agent_core.Checkpoint.t, string) result
