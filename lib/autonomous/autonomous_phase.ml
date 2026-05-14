(* Autonomous_phase — sub-phase taxonomy for the autonomous loop.
   Cycle 21 / Tier B3.

   See autonomous_phase.mli for the design rationale, especially the
   note on why [tag] mirrors the phantom witness set. *)

(* ── Phantom witness types ─────────────────────────────────────────
   Empty-variant declarations (no inhabitants). External call sites
   see them as abstract. Internal use is purely type-level — no value
   of these types is ever constructed. *)
type idle = |
type perceiving = |
type intending = |
type planning = |
type executing = |
type verifying = |
type reflecting = |
type adapting = |

(* ── Phase tag (runtime mirror) ─────────────────────────────────── *)
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

(* ── Existential phase wrapper ─────────────────────────────────── *)
type _ any =
  | Any_idle : idle any
  | Any_perceiving : perceiving any
  | Any_intending : intending any
  | Any_planning : planning any
  | Any_executing : executing any
  | Any_verifying : verifying any
  | Any_reflecting : reflecting any
  | Any_adapting : adapting any

(* GADT pattern matching requires the locally-abstract-type
   annotation [type a.] so each constructor's narrowing of 'a is
   accepted by the type checker. The body uses no payload, so each
   arm reduces to a constant tag. *)
let any_to_tag : type a. a any -> tag = function
  | Any_idle -> Tag_idle
  | Any_perceiving -> Tag_perceiving
  | Any_intending -> Tag_intending
  | Any_planning -> Tag_planning
  | Any_executing -> Tag_executing
  | Any_verifying -> Tag_verifying
  | Any_reflecting -> Tag_reflecting
  | Any_adapting -> Tag_adapting

let any_to_string : type a. a any -> string =
 fun any -> to_tla_symbol (any_to_tag any)

(* ── Transition GADT (Cycle 21 / Tier B5) ──────────────────────────
   Sub-module isolates the transition deriver output from the
   phase-tag deriver output of the same name in the enclosing module.
   Pattern: GADT for compile-time validity, regular variant `tag` as
   ppx_tla derive site, `to_tag` projection bridging the two. *)
module Transition = struct
  type ('from, 'to_) t =
    | Idle_to_perceiving : (idle, perceiving) t
    | Idle_to_adapting : (idle, adapting) t
    | Perceiving_to_idle : (perceiving, idle) t
    | Perceiving_to_intending : (perceiving, intending) t
    | Intending_to_planning : (intending, planning) t
    | Intending_to_idle : (intending, idle) t
    | Planning_to_executing : (planning, executing) t
    | Planning_to_intending : (planning, intending) t
    | Executing_to_verifying : (executing, verifying) t
    | Executing_to_adapting : (executing, adapting) t
    | Executing_to_idle : (executing, idle) t
    | Verifying_to_reflecting : (verifying, reflecting) t
    | Verifying_to_adapting : (verifying, adapting) t
    | Reflecting_to_idle : (reflecting, idle) t
    | Reflecting_to_adapting : (reflecting, adapting) t
    | Reflecting_to_planning : (reflecting, planning) t
    | Adapting_to_planning : (adapting, planning) t
    | Adapting_to_idle : (adapting, idle) t
    | Adapting_to_perceiving : (adapting, perceiving) t

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

  let to_tag : type a b. (a, b) t -> tag = function
    | Idle_to_perceiving -> T_idle_to_perceiving
    | Idle_to_adapting -> T_idle_to_adapting
    | Perceiving_to_idle -> T_perceiving_to_idle
    | Perceiving_to_intending -> T_perceiving_to_intending
    | Intending_to_planning -> T_intending_to_planning
    | Intending_to_idle -> T_intending_to_idle
    | Planning_to_executing -> T_planning_to_executing
    | Planning_to_intending -> T_planning_to_intending
    | Executing_to_verifying -> T_executing_to_verifying
    | Executing_to_adapting -> T_executing_to_adapting
    | Executing_to_idle -> T_executing_to_idle
    | Verifying_to_reflecting -> T_verifying_to_reflecting
    | Verifying_to_adapting -> T_verifying_to_adapting
    | Reflecting_to_idle -> T_reflecting_to_idle
    | Reflecting_to_adapting -> T_reflecting_to_adapting
    | Reflecting_to_planning -> T_reflecting_to_planning
    | Adapting_to_planning -> T_adapting_to_planning
    | Adapting_to_idle -> T_adapting_to_idle
    | Adapting_to_perceiving -> T_adapting_to_perceiving

  let to_string : type a b. (a, b) t -> string =
   fun t -> to_tla_symbol (to_tag t)

  (* The pair match enumerates all 8x8 = 64 (tag, tag) pairs so the
     compiler flags any new [tag] variant. The 19 valid edges mirror
     the GADT constructors above; the 45 forbidden edges are now
     explicit per "from" axis instead of being absorbed by a single
     [_, _ -> false] catch-all. Adding a 9th phase tag would silently
     inherit "no transitions" under the catch-all, masking missing
     edges; with this enumeration the compiler forces every new tag
     to be considered against every existing tag.
     Same FSM Sparse Match anti-pattern as PRs #14716, #14790, #14806,
     #14810, #14812. Constructor-name disambiguation: [Tag_*] are outer
     (phase) tags visible by parent-scope lookup; [T_*] are this
     sub-module's transition tags. *)
  let can_transition ~from_ ~to_ =
    match (any_to_tag from_, any_to_tag to_) with
    | Tag_idle, Tag_perceiving -> true
    | Tag_idle, Tag_adapting -> true
    | Tag_perceiving, Tag_idle -> true
    | Tag_perceiving, Tag_intending -> true
    | Tag_intending, Tag_planning -> true
    | Tag_intending, Tag_idle -> true
    | Tag_planning, Tag_executing -> true
    | Tag_planning, Tag_intending -> true
    | Tag_executing, Tag_verifying -> true
    | Tag_executing, Tag_adapting -> true
    | Tag_executing, Tag_idle -> true
    | Tag_verifying, Tag_reflecting -> true
    | Tag_verifying, Tag_adapting -> true
    | Tag_reflecting, Tag_idle -> true
    | Tag_reflecting, Tag_adapting -> true
    | Tag_reflecting, Tag_planning -> true
    | Tag_adapting, Tag_planning -> true
    | Tag_adapting, Tag_idle -> true
    | Tag_adapting, Tag_perceiving -> true
    | Tag_idle,
        (Tag_idle | Tag_intending | Tag_planning | Tag_executing
        | Tag_verifying | Tag_reflecting)
    | Tag_perceiving,
        (Tag_perceiving | Tag_planning | Tag_executing | Tag_verifying
        | Tag_reflecting | Tag_adapting)
    | Tag_intending,
        (Tag_perceiving | Tag_intending | Tag_executing | Tag_verifying
        | Tag_reflecting | Tag_adapting)
    | Tag_planning,
        (Tag_idle | Tag_perceiving | Tag_planning | Tag_verifying
        | Tag_reflecting | Tag_adapting)
    | Tag_executing,
        (Tag_perceiving | Tag_intending | Tag_planning | Tag_executing
        | Tag_reflecting)
    | Tag_verifying,
        (Tag_idle | Tag_perceiving | Tag_intending | Tag_planning
        | Tag_executing | Tag_verifying)
    | Tag_reflecting,
        (Tag_perceiving | Tag_intending | Tag_executing | Tag_verifying
        | Tag_reflecting)
    | Tag_adapting,
        (Tag_intending | Tag_executing | Tag_verifying | Tag_reflecting
        | Tag_adapting) -> false
end
