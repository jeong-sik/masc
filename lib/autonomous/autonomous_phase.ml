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
