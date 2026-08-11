(** Pre-inference recovery for a continuation source selected by heartbeat.

    Recovery joins the exact producer identity to its durable delivery
    obligation before allowing another model run. This prevents a connector
    outage or send crash from regenerating a second answer for the same source. *)

type outcome =
  | No_obligation
  | Obligation_committed of
      { intent : Keeper_continuation_delivery_intent.t
      ; recovery_detail : string option
      }
  | Quarantine_required of
      { intent : Keeper_continuation_delivery_intent.t option
      ; detail : string
      }

val settle_existing :
  config:Workspace.config ->
  keeper_name:string ->
  origin:Keeper_continuation_delivery_intent.origin ->
  outcome
(** Inspect and, when safe, advance the existing obligation. [No_obligation]
    alone authorizes fresh inference. Any [Obligation_committed] proves that
    response regeneration is unsafe and authorizes removal of the exact source
    from the active work queue; delivery recovery continues from the outbox.
    [Quarantine_required] removes only the affected source into a durable
    source-bearing terminal receipt so unrelated work can continue. Recovery
    loads the deterministic exact intent path; malformed peer obligations never
    poison a different source. *)
