(** Transparent proof capture middleware for CDAL.

    Part of the Contract-Driven Agent Loop (CDAL) PoC-1.

    Creates hooks that observe agent lifecycle events and accumulate
    proof data. Agent code is completely unaware of proof capture.
    Call [finalize] after agent run to write manifest and return proof.

    @stability Evolving
    @since 0.93.1 *)

(** Opaque mutable accumulator. One per agent run, not shared. *)
type state

val create
  :  store:Proof_store.config
  -> contract:Risk_contract.t
  -> mode_decision:Mode_resolver.decision
  -> capability_snapshot:Cdal_proof.capability_snapshot
  -> ?scope:string
  -> unit
  -> state

(** Returns hooks that intercept lifecycle events for proof capture.
    Compose with agent's existing hooks via [Hooks.compose]. *)
val hooks : state -> Hooks.hooks

(** Finalize: write manifest.json + contract.json to store,
    return the assembled proof bundle. *)
val finalize : state -> result_status:Cdal_proof.result_status -> Cdal_proof.t

val run_id : state -> string

(** Attach an enforcer state for evidence enrichment at finalize time. *)
val set_enforcer : state -> Mode_enforcer.state -> unit
