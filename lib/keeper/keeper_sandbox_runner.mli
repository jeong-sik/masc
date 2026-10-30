(** Backend-neutral keeper sandbox facts.

    Tool modules read the sandbox profile and the backend name from here
    instead of from a concrete sandbox backend. The production backend is
    Docker. *)

val effective_sandbox_profile :
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_types_profile_sandbox.sandbox_profile * Keeper_types_profile_sandbox.network_mode

(** The ["via"] value a write reports when the turn's sandbox runtime runs
    it. *)
val sandbox_backend_via : string
