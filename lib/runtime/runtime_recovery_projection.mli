(** Runtime-owned recovery input contract. The Keeper layer supplies closures
    bound to its validated canonical source; the runtime does not depend on
    checkpoint persistence, artifact readers, or Keeper schemas. *)
type t =
  { project : Agent_core.Agent.model_input_projection
    (** Validate and project canonical input for provider capability checks.
        The supplier owns CPU offloading and preserves typed errors. *)
  ; compose :
      Agent_core.Agent.model_input_projection option
      -> Agent_core.Agent.model_input_projection
    (** Compose the recovery view with the caller's existing projection,
        including validation after that projection. *)
  }
