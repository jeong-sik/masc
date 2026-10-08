(** Autonomous_phase — sub-phase taxonomy for the autonomous loop.

    Two closed symbol sets: the 8 phases ({!tag}) and the 19 valid
    transitions between them ({!Transition.tag}). [\[@@deriving tla\]]
    emits [to_tla_symbol], [all_symbols], and [all_states] for each; the
    [\[@tla.symbol\]] override on each constructor is the single source
    of truth for its name. *)

(** {1 Phases} *)

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

(** {1 Transitions}

    The 19 valid sub-phase transitions:

    {v
       idle       → perceiving | adapting
       perceiving → idle | intending
       intending  → planning | idle
       planning   → executing | intending
       executing  → verifying | adapting | idle
       verifying  → reflecting | adapting
       reflecting → idle | adapting | planning
       adapting   → planning | idle | perceiving
    v}

    The sub-module keeps the transition deriver output apart from the
    phase deriver output of the same name in the enclosing module. *)
module Transition : sig
  (** Each symbol is formatted ["from->to"] (e.g. ["idle->perceiving"]). *)
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
