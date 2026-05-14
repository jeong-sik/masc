(** Execution mode resolution -- deterministic downgrade logic.

    Part of the Contract-Driven Agent Loop (CDAL) PoC-1.
    Computes [effective_execution_mode] from [requested] + [risk_class]
    + [capabilities]. Never upgrades beyond requested mode.

    @stability Evolving
    @since 0.93.1 *)

type decision =
  { effective_mode : Execution_mode.t
  ; source : string
  }

(** Resolve the effective execution mode.
    Returns [Error msg] when the risk class forbids all execution
    (e.g., Critical risk). *)
val resolve
  :  requested:Execution_mode.t
  -> risk_class:Risk_class.t
  -> capabilities:Cdal_proof.capability_snapshot
  -> (decision, string) result
