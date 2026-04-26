(** Behavioral Regime Observer — pure projection wrapper.

    Wraps the minimal-input deriver in [Keeper_behavioral_regime] with a
    projection from [Keeper_registry.registry_entry], so the dashboard
    HTTP layer and fleet-matrix endpoint can call a single function
    instead of manually extracting per-entry fields.

    Contract mirrors [Keeper_composite_observer]:
    - Pure read. No mutation, no I/O, no event emission.
    - Does not read provider names, token counts, or context bytes —
      those belong to OAS (see [feedback_masc-oas-layer-boundary]).

    @since RFC-0003 Phase 3 — 7th FSM axis (behavioral regime). *)

type snapshot = Keeper_behavioral_regime.snapshot

(** Derive a behavioral-regime snapshot from a live registry entry.
    [now] is injected so the observer stays deterministic; defaults
    to [Unix.gettimeofday ()] when omitted. *)
val observe : ?now:float -> Keeper_registry.registry_entry -> snapshot

(** Observe every registered keeper under [base_path] once. Used by
    the fleet-wide regime endpoint. Preserves registry iteration order. *)
val all_snapshots : base_path:string -> unit -> snapshot list

(** Stable JSON wire format — delegates to [Keeper_behavioral_regime]. *)
val snapshot_to_json : snapshot -> Yojson.Safe.t
