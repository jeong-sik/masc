(* RFC-0107 Phase C.1 wiring tests — Eio_context.with_turn_switch
   fiber-local binding semantics.

   Verifies the four properties that make Option (3) race-free per
   audit §10.5:

   1. Binding-scope. Inside [with_turn_switch turn_sw f], reads of
      [get_switch_opt ()] return [Some turn_sw].
   2. Atomic fallback. Outside any [with_turn_switch] scope (server /
      bootstrap fibers), [get_switch_opt ()] returns the global atomic
      set by [set_switch].
   3. Fork propagation. A fiber forked from inside [with_turn_switch]
      sees the same [turn_sw] (this is the Eio.Fiber.with_binding
      contract: "propagated to any forked fibers").
   4. Sibling isolation. A sibling fiber run with [Eio.Fiber.both] in
      a separate branch does NOT see the binding from the other branch.

   Property 4 is the audit §10.2 invariant in test form: server fibers
   that are siblings of (or above) the keeper run_turn fiber tree must
   not see turn_sw. This codifies the structural separation that makes
   the §5 race scenario impossible. *)

let test_get_switch_opt_returns_binding_inside_with_turn_switch () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun outer_sw ->
  (* Establish a global atomic (= server root_sw) for fallback comparison. *)
  Eio_context.set_switch outer_sw;
  Eio.Switch.run @@ fun turn_sw ->
  Eio_context.with_turn_switch turn_sw @@ fun () ->
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Alcotest.(check bool)
      "fiber-local binding returns turn_sw, not outer_sw"
      true
      (sw == turn_sw)
  | None ->
    Alcotest.fail "get_switch_opt returned None inside with_turn_switch"

let test_get_switch_opt_falls_through_to_atomic_outside_binding () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun root_sw ->
  Eio_context.set_switch root_sw;
  (* No with_turn_switch wrap → fiber-local is empty → atomic fallback. *)
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Alcotest.(check bool)
      "outside binding, get_switch_opt returns root_sw atomic"
      true
      (sw == root_sw)
  | None ->
    Alcotest.fail "atomic was set but get_switch_opt returned None"

let test_binding_propagates_to_forked_child () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun outer_sw ->
  Eio_context.set_switch outer_sw;
  Eio.Switch.run @@ fun turn_sw ->
  Eio_context.with_turn_switch turn_sw @@ fun () ->
  let child_saw = Atomic.make None in
  Eio.Fiber.fork ~sw:turn_sw (fun () ->
    Atomic.set child_saw (Eio_context.get_switch_opt ()));
  (* Wait for the forked child to complete before leaving with_turn_switch.
     Eio.Switch.run won't return until all fibers attached to turn_sw
     finish, but the local atomic read needs to happen first. We use
     yields to let the child run. *)
  Eio.Fiber.yield ();
  match Atomic.get child_saw with
  | Some sw ->
    Alcotest.(check bool)
      "forked child inherits turn_sw binding (Fiber.with_binding contract)"
      true
      (sw == turn_sw)
  | None ->
    Alcotest.fail "forked child did not read fiber-local binding"

let test_binding_does_not_leak_to_sibling_fiber () =
  (* This is the structural separation invariant. If keeper run_turn
     binds turn_sw on its own fiber, a sibling fiber (e.g. dashboard
     server, board_dispatch) running concurrently via Eio.Fiber.both
     must NOT see turn_sw — its [Fiber.get] returns None, falling
     through to the atomic. *)
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun root_sw ->
  Eio_context.set_switch root_sw;
  Eio.Switch.run @@ fun turn_sw ->
  let sibling_saw = Atomic.make None in
  Eio.Fiber.both
    (fun () ->
       Eio_context.with_turn_switch turn_sw @@ fun () ->
       Eio.Fiber.yield ())
    (fun () ->
       Eio.Fiber.yield ();
       Atomic.set sibling_saw (Eio_context.get_switch_opt ()));
  match Atomic.get sibling_saw with
  | Some sw ->
    (* Sibling must see root_sw (atomic fallback), not turn_sw. *)
    Alcotest.(check bool)
      "sibling fiber sees root_sw atomic, NOT the other branch's turn_sw"
      true
      (sw == root_sw && not (sw == turn_sw))
  | None ->
    Alcotest.fail "sibling fiber read None — atomic should be set"

let test_binding_cleared_after_with_turn_switch_exits () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun root_sw ->
  Eio_context.set_switch root_sw;
  Eio.Switch.run @@ fun turn_sw ->
  Eio_context.with_turn_switch turn_sw (fun () -> ());
  (* After with_turn_switch returns, the binding should be gone. *)
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Alcotest.(check bool)
      "after with_turn_switch exits, get_switch_opt falls back to atomic"
      true
      (sw == root_sw && not (sw == turn_sw))
  | None ->
    Alcotest.fail "atomic was set; fallback should have returned root_sw"

let () =
  Alcotest.run "eio_context_fiber_local"
    [
      ( "binding scope",
        [
          Alcotest.test_case "inside with_turn_switch → turn_sw"
            `Quick
            test_get_switch_opt_returns_binding_inside_with_turn_switch;
          Alcotest.test_case "outside binding → atomic fallback"
            `Quick
            test_get_switch_opt_falls_through_to_atomic_outside_binding;
          Alcotest.test_case "binding cleared after exit"
            `Quick
            test_binding_cleared_after_with_turn_switch_exits;
        ] );
      ( "fork propagation",
        [
          Alcotest.test_case "forked child inherits binding"
            `Quick
            test_binding_propagates_to_forked_child;
        ] );
      ( "structural separation (audit §10.2)",
        [
          Alcotest.test_case "sibling fiber does not see binding"
            `Quick
            test_binding_does_not_leak_to_sibling_fiber;
        ] );
    ]
