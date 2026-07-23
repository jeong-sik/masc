(** Keeper_registry_types_decision — decision_stage FSM types and transitions.

    Extracted from [Keeper_registry_types] (658 LoC). Pure type definitions
    and functions for the decision_stage GADT, witnesses, and transition matrix.

    @since Keeper 500-line decomposition *)

type decision_stage =
  | Decision_undecided [@tla.idle]
  | Decision_guard_ok [@tla.active]
  | Decision_tool_policy_selected [@tla.active]
[@@deriving tla]

type decision_undecided = |
type decision_guard_ok = |
type decision_tool_policy_selected = |

type 'a decision_stage_witness =
  | Decision_undecided : decision_undecided decision_stage_witness
  | Decision_guard_ok : decision_guard_ok decision_stage_witness
  | Decision_tool_policy_selected : decision_tool_policy_selected decision_stage_witness

type packed_decision_stage = Packed : 'a decision_stage_witness -> packed_decision_stage

let witness_to_stage : type a. a decision_stage_witness -> decision_stage = function
  | Decision_undecided -> Decision_undecided
  | Decision_guard_ok -> Decision_guard_ok
  | Decision_tool_policy_selected -> Decision_tool_policy_selected
;;

let stage_to_witness : decision_stage -> packed_decision_stage = function
  | Decision_undecided -> Packed Decision_undecided
  | Decision_guard_ok -> Packed Decision_guard_ok
  | Decision_tool_policy_selected -> Packed Decision_tool_policy_selected
;;

(* Decision stages valid as ADVANCE targets within a turn.
   Excludes [Decision_undecided] (the initial state, set only by
   [mark_turn_started] / [mark_sdk_turn_started]).  The 2 spec-forbidden
   [<active>_to_undecided] transitions are unrepresentable through this
   type, replacing the prior runtime [invalid_arg] inside
   [set_turn_decision_stage]. *)
type decision_stage_active =
  | Decision_active_guard_ok
  | Decision_active_tool_policy_selected

let decision_stage_active_to_packed : decision_stage_active -> packed_decision_stage =
  function
  | Decision_active_guard_ok -> Packed Decision_guard_ok
  | Decision_active_tool_policy_selected -> Packed Decision_tool_policy_selected
;;

(* Diagnostic label for invalid-transition error messages.  Mirrors
   [decision_stage]; constructor changes will fail compilation here. *)
let packed_decision_stage_label : packed_decision_stage -> string = function
  | Packed Decision_undecided -> "Decision_undecided"
  | Packed Decision_guard_ok -> "Decision_guard_ok"
  | Packed Decision_tool_policy_selected -> "Decision_tool_policy_selected"
;;

module Decision_transition = struct
  type ('from, 'to_) t =
    | Undecided_to_guard_ok : (decision_undecided, decision_guard_ok) t
    | Undecided_to_tool_policy_selected :
        (decision_undecided, decision_tool_policy_selected) t
    | Guard_ok_to_tool_policy_selected :
        (decision_guard_ok, decision_tool_policy_selected) t
    | Tool_policy_selected_to_guard_ok :
        (decision_tool_policy_selected, decision_guard_ok) t

  let to_tag : type a b. (a, b) t -> string = function
    | Undecided_to_guard_ok -> "undecided->guard_ok"
    | Undecided_to_tool_policy_selected -> "undecided->tool_policy_selected"
    | Guard_ok_to_tool_policy_selected -> "guard_ok->tool_policy_selected"
    | Tool_policy_selected_to_guard_ok -> "tool_policy_selected->guard_ok"
  ;;
end

(* Living-matrix documentation of the decision-stage transition relation.
   Forbidden [<active>_to_undecided] pairs are unrepresentable through
   the [decision_stage_active] target type (PR #14887 made
   [set_turn_decision_stage] reject them at compile time; this
   validator mirrors that invariant at the test surface).

   We pattern-match on the raw [decision_stage] / [decision_stage_active]
   variants — *not* on the packed GADT witnesses returned by
   [stage_to_witness] / [decision_stage_active_to_packed].  The packed
   wrappers existentially quantify away the witness phantom, after
   which the compiler can no longer see that [decision_stage_active]
   has no [Decision_active_undecided] constructor; Warning 8 then
   spuriously demands the unreachable [(Packed Decision_undecided,
   Packed Decision_undecided)] case (regression introduced by #14893).

   By matching directly on the source variants the exhaustiveness
   check ranges over the *actual* input domain: 3 [decision_stage]
   sources × 2 [decision_stage_active] targets = 6 admitted pairs,
   no false-positive cases.  Adding a new [decision_stage] or
   [decision_stage_active] constructor still fails Warning 8 here,
   preserving the original tripwire intent. *)
let validate_decision_transition ~(from : decision_stage) ~(to_ : decision_stage_active) =
  match from, to_ with
  | Decision_undecided, Decision_active_guard_ok -> ()
  | Decision_undecided, Decision_active_tool_policy_selected -> ()
  | Decision_guard_ok, Decision_active_guard_ok -> ()
  | Decision_guard_ok, Decision_active_tool_policy_selected -> ()
  | Decision_tool_policy_selected, Decision_active_guard_ok -> ()
  | Decision_tool_policy_selected, Decision_active_tool_policy_selected -> ()
;;
