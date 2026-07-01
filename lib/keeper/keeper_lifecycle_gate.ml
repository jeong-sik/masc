(* RFC-0297 Phase 1 (P0-1): closed-variant keeper lifecycle gate.
   See keeper_lifecycle_gate.mli for the contract. *)

type gate =
  | Reactive
  | Proactive
  | Autonomous
  | Bootstrap

type flags =
  { reactive : bool
  ; proactive : bool
  ; autonomous : bool
  ; bootstrap : bool
  }

let all_enabled =
  { reactive = true; proactive = true; autonomous = true; bootstrap = true }

let gate_enabled gate ~(global : flags) ~(meta : flags) =
  (* Exhaustive by construction: a new [gate] variant fails to compile
     until it selects its global/meta flags here. Both must be true —
     a lifecycle activity is enabled only when neither the global
     kill-switch nor the per-keeper flag has opted out. *)
  match gate with
  | Reactive -> global.reactive && meta.reactive
  | Proactive -> global.proactive && meta.proactive
  | Autonomous -> global.autonomous && meta.autonomous
  | Bootstrap -> global.bootstrap && meta.bootstrap

let gate_to_string = function
  | Reactive -> "reactive"
  | Proactive -> "proactive"
  | Autonomous -> "autonomous"
  | Bootstrap -> "bootstrap"
