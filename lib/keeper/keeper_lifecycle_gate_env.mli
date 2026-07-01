(** RFC-0297 Phase 1 (P0-1): impure shell + SSOT resolver for the keeper
    lifecycle gates. The gate LOGIC stays in the pure {!Keeper_lifecycle_gate};
    this module owns the env read and the [keeper_meta] projection
    (RFC-OAS-024 pure-core / impure-shell). Every call site resolves a gate
    through {!enabled}, so the enabled decision is never re-derived inline. *)

(** Global lifecycle kill-switches read from the feature-flag registry
    (MASC_KEEPER_REACTIVE_ENABLED / _PROACTIVE_ENABLED / _AUTONOMOUS_ENABLED /
    _BOOTSTRAP_ENABLED). Every flag defaults to [true]. *)
val global : unit -> Keeper_lifecycle_gate.flags

(** Project a keeper's per-keeper gate flags from its meta. SSOT for which
    meta field backs each gate: [reactive] has no per-keeper flag (global
    only); [proactive] = [meta.proactive.enabled]; [autonomous] and
    [bootstrap] = [meta.autoboot_enabled]. *)
val meta_flags : Keeper_meta_contract.keeper_meta -> Keeper_lifecycle_gate.flags

(** [enabled gate m] is [true] iff [gate] is enabled for keeper [m] — the
    global kill-switch AND the per-keeper flag. The single resolver every
    lifecycle-gate call site uses. *)
val enabled : Keeper_lifecycle_gate.gate -> Keeper_meta_contract.keeper_meta -> bool
