(** Exact retained input state observed through the current Keeper Owner.
    This read contract supports host/reconnect/TUI observation, not response
    acceptance or continuation dispatch. A stale/corrupt canonical cannot
    resurrect a consumed request or hide an owned pending request. *)
type t =
  | Unobserved of Keeper_id.Trace_id.t
  | Pending of { checkpoint : Keeper_checkpoint_ref.t;
                 pending : Agent_core.Agent_input_request.pending }
  | Consumed of Keeper_checkpoint_ref.t

type error =
  | Owner_unavailable of Keeper_owner_registry.command_error
  | Trace_changed of { expected : Keeper_id.Trace_id.t; actual : Keeper_id.Trace_id.t }
  | Prior_input_unavailable
  | Retained_unavailable of Keeper_checkpoint_store.checkpoint_cas_error

val read : base_path:string -> keeper_name:string -> expected_trace:Keeper_id.Trace_id.t ->
  (t, error) result
(** One Owner mailbox read captures the trace, original session root and exact
    journal reference, then the reader validates that retained artifact. No
    canonical/history fallback and no reconstruction from latest-turn counters.
    Unobserved is possible only under the journal's fresh-history contract.
    Pending and Consumed both retain the exact owned reference. This snapshot
    can become stale after return and never grants mutation authority. *)
val to_json : (t, error) result -> Yojson.Safe.t
(** Host observation v2. Source is retained_input_owner; statuses are unobserved,
    owned_pending, owned_none and unavailable. Failure preserves its category
    and never publishes a borrowed request or fabricated checkpoint reference. *)
