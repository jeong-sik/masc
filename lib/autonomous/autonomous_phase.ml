(* Autonomous_phase — sub-phase taxonomy for the autonomous loop.
   See autonomous_phase.mli. *)

type tag =
  | Tag_idle [@tla.symbol "idle"]
  | Tag_perceiving [@tla.symbol "perceiving"]
  | Tag_intending [@tla.symbol "intending"]
  | Tag_planning [@tla.symbol "planning"]
  | Tag_executing [@tla.symbol "executing"]
  | Tag_verifying [@tla.symbol "verifying"]
  | Tag_reflecting [@tla.symbol "reflecting"]
  | Tag_adapting [@tla.symbol "adapting"]
[@@deriving tla]

(* Sub-module so the transition deriver output does not clash with the
   phase-tag deriver output of the same name in the enclosing module. *)
module Transition = struct
  type tag =
    | T_idle_to_perceiving [@tla.symbol "idle->perceiving"]
    | T_idle_to_adapting [@tla.symbol "idle->adapting"]
    | T_perceiving_to_idle [@tla.symbol "perceiving->idle"]
    | T_perceiving_to_intending [@tla.symbol "perceiving->intending"]
    | T_intending_to_planning [@tla.symbol "intending->planning"]
    | T_intending_to_idle [@tla.symbol "intending->idle"]
    | T_planning_to_executing [@tla.symbol "planning->executing"]
    | T_planning_to_intending [@tla.symbol "planning->intending"]
    | T_executing_to_verifying [@tla.symbol "executing->verifying"]
    | T_executing_to_adapting [@tla.symbol "executing->adapting"]
    | T_executing_to_idle [@tla.symbol "executing->idle"]
    | T_verifying_to_reflecting [@tla.symbol "verifying->reflecting"]
    | T_verifying_to_adapting [@tla.symbol "verifying->adapting"]
    | T_reflecting_to_idle [@tla.symbol "reflecting->idle"]
    | T_reflecting_to_adapting [@tla.symbol "reflecting->adapting"]
    | T_reflecting_to_planning [@tla.symbol "reflecting->planning"]
    | T_adapting_to_planning [@tla.symbol "adapting->planning"]
    | T_adapting_to_idle [@tla.symbol "adapting->idle"]
    | T_adapting_to_perceiving [@tla.symbol "adapting->perceiving"]
  [@@deriving tla]
end
