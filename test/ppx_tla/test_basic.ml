(* Cycle 2 + Cycle 3 tests for ppx_tla deriver.

   Cycle 2 (PR #11377): nullary [to_tla_symbol] and [all_states].
   Cycle 3 (this commit) extensions exercised below:
   - parameterised constructors (match with [_] payload)
   - [@tla.symbol "explicit"] override
   - [all_symbols] always generated
   - [all_states] generated only when every constructor is nullary
   - [@tla.terminal] / [@tla.active] / [@tla.idle] classification
     emits symbol subsets and payload-safe predicates

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

module Classified = struct
  type t =
    | Idle [@tla.idle]
    | Running [@tla.active]
    | Awaiting_tool [@tla.symbol "awaiting_tool"] [@tla.active]
    | Done [@tla.terminal]
    | Failed of Reason.t [@tla.terminal]
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

let test_classified_symbol_subsets () =
  assert (Classified.idle_symbols = [ "idle" ]);
  assert (Classified.active_symbols = [ "running"; "awaiting_tool" ]);
  assert (Classified.terminal_symbols = [ "done"; "failed" ])

let test_classified_predicates () =
  assert (Classified.is_idle Classified.Idle);
  assert (not (Classified.is_idle Classified.Running));
  assert (Classified.is_active Classified.Running);
  assert (Classified.is_active Classified.Awaiting_tool);
  assert (not (Classified.is_active Classified.Done));
  assert (Classified.is_terminal Classified.Done);
  assert (Classified.is_terminal (Classified.Failed "boom"));
  assert (not (Classified.is_terminal Classified.Idle))

(* Cycle 12 (PR #11450): [@@fsm_guard "expr"] runtime assertion injection.
   The guard is parsed as an OCaml boolean expression at PPX time and
   injected through [Keeper_fsm_guard_runtime.wrap_unit] into the function
   body. For curried bindings the wrapped assert lands in the innermost
   lambda so it fires per application, not per partial application. *)

let f_with_guard x = x + 1
[@@fsm_guard "x >= 0"]

let test_fsm_guard_pass () =
  assert (f_with_guard 5 = 6);
  assert (f_with_guard 0 = 1)

let test_fsm_guard_fail () =
  let raised =
    try
      ignore (f_with_guard (-1));
      false
    with Assert_failure _ -> true
  in
  assert raised

(* Curried form: assert lands in the innermost lambda body so it fires
   only when the second argument is applied, not when [g_curried 100] is
   partially evaluated. *)

let g_curried a b = a + b
[@@fsm_guard "a + b >= 0"]

let test_fsm_guard_curried_pass () =
  assert (g_curried 2 3 = 5);
  let _partial = g_curried 100 in
  ()

let test_fsm_guard_curried_fail () =
  let raised =
    try
      ignore (g_curried 1 (-5));
      false
    with Assert_failure _ -> true
  in
  assert raised

(* Verify that [wrap_unit] was actually called by the PPX-generated code,
   not just a bare assert.  The stub tracks invocations. *)
let test_wrap_unit_routing () =
  Keeper_fsm_guard_runtime.reset_invocations ();
  let _ = f_with_guard 5 in
  let invocations = Keeper_fsm_guard_runtime.get_invocations () in
  assert (List.length invocations >= 1);
  let (action, stage) = List.hd invocations in
  assert (action = "f_with_guard");
  assert (stage = "guard")

let test_wrap_unit_routing_curried () =
  Keeper_fsm_guard_runtime.reset_invocations ();
  let _ = g_curried 2 3 in
  let invocations = Keeper_fsm_guard_runtime.get_invocations () in
  assert (List.length invocations >= 1);
  let (action, stage) = List.hd invocations in
  assert (action = "g_curried");
  assert (stage = "guard")

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
  test_classified_symbol_subsets ();
  test_classified_predicates ();
  test_fsm_guard_pass ();
  test_fsm_guard_fail ();
  test_fsm_guard_curried_pass ();
  test_fsm_guard_curried_fail ();
  test_wrap_unit_routing ();
  test_wrap_unit_routing_curried ();
  print_endline "ppx_tla cycle 2 + 3 + 12 tests: PASS"
