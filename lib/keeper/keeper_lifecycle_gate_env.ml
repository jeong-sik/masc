(* RFC-0297 Phase 1 (P0-1): impure shell that reads the global lifecycle
   kill-switches from the feature-flag registry into the pure
   Keeper_lifecycle_gate.flags. Kept separate from Keeper_lifecycle_gate so
   the gate logic stays pure and unit-testable; this module owns the
   env/boot-override read (RFC-OAS-024 pure-core / impure-shell). *)

let global () : Keeper_lifecycle_gate.flags =
  { reactive = Feature_flag_registry.get_bool "MASC_KEEPER_REACTIVE_ENABLED"
  ; proactive = Feature_flag_registry.get_bool "MASC_KEEPER_PROACTIVE_ENABLED"
  ; autonomous = Feature_flag_registry.get_bool "MASC_KEEPER_AUTONOMOUS_ENABLED"
  ; bootstrap = Feature_flag_registry.get_bool "MASC_KEEPER_BOOTSTRAP_ENABLED"
  }
