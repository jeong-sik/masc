(* Cycle 2 + Cycle 3 tests for ppx_tla deriver.

   Cycle 2 (PR #11377): nullary [to_tla_symbol] and [all_states].
   Cycle 3 (this commit) extensions exercised below:
   - parameterised constructors (match with [_] payload)
   - [@tla.symbol "explicit"] override
   - [all_symbols] always generated
   - [all_states] generated only when every constructor is nullary

   Each type is wrapped in its own module because [@@deriving tla]
   generates [to_tla_symbol] / [all_symbols] / [all_states] in the
   surrounding scope; nesting modules keeps the helpers per-type
   rather than the second type silently shadowing the first. *)

module Color = struct
  type t = Red | Green | Blue [@@deriving tla]
end

module Turn_state = struct
  type t =
    | Idle
    | Phase_gating
    | Cascade_routing
    | Done
  [@@deriving tla]
end

(* Cycle 3: parameterised constructors with [@tla.symbol] override. *)
module Reason = struct
  type t = string

  let of_string s = s
end

module Mixed = struct
  type t =
    | Awaiting_provider
    | Awaiting_tool_result [@tla.symbol "awaiting_tool"]
    | Failed of Reason.t
    | Cancelled of Reason.t
  [@@deriving tla]
end

let test_color_to_tla_symbol () =
  assert (Color.to_tla_symbol Color.Red = "red");
  assert (Color.to_tla_symbol Color.Green = "green");
  assert (Color.to_tla_symbol Color.Blue = "blue")

let test_color_all_states () =
  assert (Color.all_states = [ Color.Red; Color.Green; Color.Blue ])

let test_color_all_symbols () =
  assert (Color.all_symbols = [ "red"; "green"; "blue" ])

let test_turn_state_to_tla_symbol () =
  assert (Turn_state.to_tla_symbol Turn_state.Idle = "idle");
  assert (Turn_state.to_tla_symbol Turn_state.Phase_gating = "phase_gating");
  assert (
    Turn_state.to_tla_symbol Turn_state.Cascade_routing = "cascade_routing");
  assert (Turn_state.to_tla_symbol Turn_state.Done = "done")

let test_turn_state_all_states () =
  assert (
    Turn_state.all_states
    = [
        Turn_state.Idle;
        Turn_state.Phase_gating;
        Turn_state.Cascade_routing;
        Turn_state.Done;
      ])

(* Cycle 3 verifications. *)

let test_mixed_to_tla_symbol_default () =
  assert (Mixed.to_tla_symbol Mixed.Awaiting_provider = "awaiting_provider")

let test_mixed_to_tla_symbol_override () =
  (* [@tla.symbol "awaiting_tool"] overrides the default
     [String.lowercase_ascii "Awaiting_tool_result"]. *)
  assert (Mixed.to_tla_symbol Mixed.Awaiting_tool_result = "awaiting_tool")

let test_mixed_to_tla_symbol_parameterised () =
  let r = Reason.of_string "irrelevant" in
  assert (Mixed.to_tla_symbol (Mixed.Failed r) = "failed");
  assert (Mixed.to_tla_symbol (Mixed.Cancelled r) = "cancelled")

let test_mixed_all_symbols () =
  (* all_symbols works even when constructors carry payloads. *)
  assert (
    Mixed.all_symbols
    = [ "awaiting_provider"; "awaiting_tool"; "failed"; "cancelled" ])

let () =
  test_color_to_tla_symbol ();
  test_color_all_states ();
  test_color_all_symbols ();
  test_turn_state_to_tla_symbol ();
  test_turn_state_all_states ();
  test_mixed_to_tla_symbol_default ();
  test_mixed_to_tla_symbol_override ();
  test_mixed_to_tla_symbol_parameterised ();
  test_mixed_all_symbols ();
  print_endline "ppx_tla cycle 2 + 3 tests: PASS"
