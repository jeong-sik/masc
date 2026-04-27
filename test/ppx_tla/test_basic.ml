(* Cycle 2 minimal test for ppx_tla deriver.
   Verifies that [@@deriving tla] generates [to_tla_symbol] mapping
   constructors to lowercased names, and [all_states] enumerating
   every constructor in declaration order.

   Each type is wrapped in its own module because [@@deriving tla]
   generates [to_tla_symbol] / [all_states] in the surrounding scope;
   nesting modules keeps the helpers per-type rather than the second
   type silently shadowing the first. *)

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

let test_color_to_tla_symbol () =
  assert (Color.to_tla_symbol Color.Red = "red");
  assert (Color.to_tla_symbol Color.Green = "green");
  assert (Color.to_tla_symbol Color.Blue = "blue")

let test_color_all_states () =
  assert (Color.all_states = [ Color.Red; Color.Green; Color.Blue ])

let test_turn_state_to_tla_symbol () =
  assert (Turn_state.to_tla_symbol Turn_state.Idle = "idle");
  assert (Turn_state.to_tla_symbol Turn_state.Phase_gating = "phase_gating");
  assert (Turn_state.to_tla_symbol Turn_state.Cascade_routing = "cascade_routing");
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

let () =
  test_color_to_tla_symbol ();
  test_color_all_states ();
  test_turn_state_to_tla_symbol ();
  test_turn_state_all_states ();
  print_endline "ppx_tla basic test: PASS"
