(* RFC-0297 Phase 1 (P0-1): impure shell + SSOT resolver for the keeper
   lifecycle gates. The gate LOGIC stays in the pure Keeper_lifecycle_gate
   module; this module owns the two projections (Agent Core contract pure-core /
   impure-shell):

     - [global]     : read the MASC_KEEPER_*_ENABLED kill-switches.
     - [meta_flags] : project keeper_meta onto the per-keeper gate flags.

   Every call site resolves a gate through the single [enabled] function, so
   the enabled decision is never re-derived inline (one SSOT, not scattered
   per-site judgments). *)

open Keeper_meta_contract

(* Global kill-switches from the feature-flag registry. All default true. *)
let global () : Keeper_lifecycle_gate.flags =
  let autonomous = Feature_flag_registry.get_bool "MASC_KEEPER_AUTONOMOUS_ENABLED" in
  { reactive = Feature_flag_registry.get_bool "MASC_KEEPER_REACTIVE_ENABLED"
  ; proactive = autonomous
  ; autonomous
  ; bootstrap = autonomous
  }

(* One declarative mode owns both spontaneous initiative and automatic owner
   restoration. Requested work is admitted separately from this projection. *)
let meta_flags (m : keeper_meta) : Keeper_lifecycle_gate.flags =
  { reactive = true
  ; proactive = Keeper_activation_mode.spontaneous m.activation_mode
  ; autonomous = Keeper_activation_mode.restore_owner m.activation_mode
  ; bootstrap = Keeper_activation_mode.restore_owner m.activation_mode
  }

(* The single resolver every lifecycle-gate call site uses:
   global kill-switch AND per-keeper flag. *)
let enabled (gate : Keeper_lifecycle_gate.gate) (m : keeper_meta) : bool =
  Keeper_lifecycle_gate.gate_enabled gate ~global:(global ()) ~meta:(meta_flags m)
