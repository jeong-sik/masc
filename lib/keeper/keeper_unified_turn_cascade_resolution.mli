(** Cascade routing resolution stage extracted from
    [Keeper_unified_turn.run_keeper_cycle] per RFC-0136 PR-2.

    Owns the [selected_item] override of [meta.cascade_ref], the
    [Keeper_cascade_routing.select_cascade] call, and the
    [fail_open_local_only_when_unavailable] hardening of the resolved
    cascade. Returns both the updated meta and the resolved cascade so
    the caller can resume with downstream pre-dispatch validation. *)

type cascade_resolution =
  { resolved_meta : Keeper_types.keeper_meta
    (** [meta] with [cascade_ref] potentially overridden by
        [selected_item] and with cascade name aligned to routing. *)
  ; resolved_cascade : string
    (** Final cascade name after probeable-runtime fail-open. *)
  }

val resolve_cascade
  :  meta:Keeper_types.keeper_meta
  -> phase_opt:Keeper_state_machine.phase option
  -> selected_item:(string * Cascade_ref.cascade_item) option
  -> append_cascade_routed_manifest:
       (cascade_name:string -> decision:Yojson.Safe.t -> unit)
  -> cascade_resolution
(** Resolve cascade routing.

    Side effects:
    - Increments [Keeper_metrics.metric_keeper_fsm_edge_transitions]
      with the [ksm_to_kcl_routing] edge label.
    - Emits debug log for the base-to-effective cascade transition.
    - Emits warn log when [fail_open_local_only_when_unavailable] falls
      back to the base cascade.
    - Invokes [append_cascade_routed_manifest] once with the resolved
      cascade name and the routing decision JSON.

    The function is total: it always returns a [cascade_resolution]
    value. Failures inside the routing dependencies surface as logs
    rather than exceptions. *)
