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

(** The HTTPS connector cache is stored as an [Atomic.t] cell so that
    concurrent reads from multiple OCaml 5 domains do not race on a plain
    [ref].  Calling the public getter repeatedly must return a stable result
    (Ok/Ok or Error/Error with the same message). *)
let test_get_https_connector_result_is_idempotent () =
  let a = Eio_context.get_https_connector_result () in
  let b = Eio_context.get_https_connector_result () in
  match (a, b) with
  | Ok _, Ok _ ->
    Alcotest.(check pass) "repeated connector reads are both Ok" () ()
  | Error e1, Error e2 ->
    Alcotest.(check string) "repeated connector reads return the same error" e1 e2
  | _ ->
    Alcotest.fail "HTTPS connector result is not stable across repeated reads"

(** The Board flusher is a process-lifetime daemon that may attach to the
    server root switch. The owner domain that installed that switch must see
    [true], while a worker domain reading the same process-global binding must
    see [false]. The switch and owner are published as one atomic binding. *)
let test_root_switch_ownership_is_domain_local () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun root_sw ->
  Eio_context.set_switch root_sw;
  Alcotest.(check bool)
    "owner domain owns the root switch"
    true
    (Eio_context.root_switch_on_current_domain ());
  let worker_saw_ownership =
    Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
      Eio_context.root_switch_on_current_domain ())
  in
  Alcotest.(check bool)
    "worker domain does not own the root switch"
    false
    worker_saw_ownership

let test_run_on_owner_domain_inline_when_uninitialized () =
  let ran = Eio_context.run_on_owner_domain (fun () -> 42) in
  Alcotest.(check int) "inline without root switch returns value" 42 ran;
  let raised =
    try
      Eio_context.run_on_owner_domain (fun () ->
          (failwith "uninitialized error" : unit));
      false
    with
    | Failure msg when String.equal msg "uninitialized error" -> true
    | _ -> false
  in
  Alcotest.(check bool) "inline without root switch raises exception" true raised

let test_run_on_owner_domain_inline_on_owner_domain () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun root_sw ->
  Eio_context.set_switch root_sw;
  let ran = Eio_context.run_on_owner_domain (fun () -> 123) in
  Alcotest.(check int) "inline on owner domain returns value" 123 ran;
  let raised =
    try
      Eio_context.run_on_owner_domain (fun () ->
          (failwith "owner error" : unit));
      false
    with
    | Failure msg when String.equal msg "owner error" -> true
    | _ -> false
  in
  Alcotest.(check bool) "inline on owner domain raises exception" true raised

let test_run_on_owner_domain_cross_domain_dispatch () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun root_sw ->
  Eio_context.set_switch root_sw;
  let owner_domain = Domain.self () in
  Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
    let worker_domain = Domain.self () in
    Alcotest.(check bool)
      "worker domain is distinct from owner domain"
      true
      (worker_domain <> owner_domain);
    (* 1. Verify direct fork on root_sw from worker domain raises Switch accessed from wrong domain *)
    let direct_fork_raised_wrong_domain =
      try
        Eio.Fiber.fork ~sw:root_sw (fun () -> ());
        false
      with
      | Invalid_argument msg when String.equal msg "Switch accessed from wrong domain!" -> true
      | _ -> false
    in
    Alcotest.(check bool)
      "direct fork on root_sw from worker domain raises Switch accessed from wrong domain!"
      true
      direct_fork_raised_wrong_domain;
    (* 2. Verify run_on_owner_domain executes on owner domain and allows forking on root_sw *)
    let forked_child_ran = Atomic.make false in
    let executed_domain =
      Eio_context.run_on_owner_domain (fun () ->
        Eio.Fiber.fork ~sw:root_sw (fun () ->
          Atomic.set forked_child_ran true);
        Domain.self ())
    in
    Alcotest.(check bool)
      "task executed on owner domain, not worker domain"
      true
      (executed_domain = owner_domain);
    Alcotest.(check bool)
      "forked child on root_sw executed successfully"
      true
      (Atomic.get forked_child_ran);
    (* 3. Verify exception propagation across domains *)
    let cross_domain_exception_propagated =
      try
        Eio_context.run_on_owner_domain (fun () ->
          (failwith "cross-domain error payload" : unit));
        false
      with
      | Failure msg when String.equal msg "cross-domain error payload" -> true
      | _ -> false
    in
    Alcotest.(check bool)
      "exception on owner domain re-raised on worker domain"
      true
      cross_domain_exception_propagated;
    (* 4. Verify Cancelled exception propagation does NOT crash or cancel root_sw *)
    let cancelled_propagated =
      try
        Eio_context.run_on_owner_domain (fun () ->
          (raise (Eio.Cancel.Cancelled (Failure "simulated cancel")) : unit));
        false
      with
      | Eio.Cancel.Cancelled (Failure msg) when String.equal msg "simulated cancel" -> true
      | _ -> false
    in
    Alcotest.(check bool)
      "Cancelled exception propagated to worker domain"
      true
      cancelled_propagated;
    (* Verify root_sw is still healthy and accepting work *)
    let post_cancel_ran =
      Eio_context.run_on_owner_domain (fun () -> 999)
    in
    Alcotest.(check int)
      "root_sw still alive and operational after inner Cancelled"
      999
      post_cancel_ran)

let test_set_switch_clears_on_release () =
  Eio_main.run @@ fun _env ->
  Eio_context.For_testing.clear_root_switch ();
  Alcotest.(check bool) "root switch initially None" true
    (Option.is_none (Eio_context.get_root_switch_opt ()));
  Eio.Switch.run (fun sw ->
    Eio_context.set_switch sw;
    Alcotest.(check bool) "root switch set while active" true
      (Option.is_some (Eio_context.get_root_switch_opt ())));
  Alcotest.(check bool) "root switch cleared after switch released" true
    (Option.is_none (Eio_context.get_root_switch_opt ()))

let test_with_turn_switch_does_not_mutate_root_switch () =
  Eio_main.run @@ fun _env ->
  Eio_context.For_testing.clear_root_switch ();
  Eio.Switch.run @@ fun root_sw ->
  Eio_context.set_switch root_sw;
  Eio.Switch.run @@ fun request_sw ->
  let inside_saw_request_sw = Atomic.make false in
  let inside_root_switch_preserved = Atomic.make false in
  Eio_context.with_turn_switch request_sw (fun () ->
    (match Eio_context.get_switch_opt () with
     | Some sw -> Atomic.set inside_saw_request_sw (sw == request_sw)
     | None -> ());
    (match Eio_context.get_root_switch_opt () with
     | Some sw -> Atomic.set inside_root_switch_preserved (sw == root_sw)
     | None -> ()));
  Alcotest.(check bool) "with_turn_switch provides request switch to get_switch_opt" true
    (Atomic.get inside_saw_request_sw);
  Alcotest.(check bool) "with_turn_switch preserves root switch in get_root_switch_opt" true
    (Atomic.get inside_root_switch_preserved);
  (match Eio_context.get_switch_opt () with
   | Some sw -> Alcotest.(check bool) "after with_turn_switch, fallback returns root_sw" true (sw == root_sw)
   | None -> Alcotest.fail "expected root switch fallback");
  Eio_context.For_testing.clear_root_switch ()

let test_for_testing_clear_root_switch () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.set_switch sw;
  Alcotest.(check bool) "set_switch installed" true
    (Option.is_some (Eio_context.get_root_switch_opt ()));
  Eio_context.For_testing.clear_root_switch ();
  Alcotest.(check bool) "clear_root_switch reset to None" true
    (Option.is_none (Eio_context.get_root_switch_opt ()))

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
          Alcotest.test_case "with_turn_switch does not mutate root switch"
            `Quick
            test_with_turn_switch_does_not_mutate_root_switch;
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
      ( "HTTPS connector atomic cache",
        [
          Alcotest.test_case "get_https_connector_result is idempotent"
            `Quick
            test_get_https_connector_result_is_idempotent;
        ] );
      ( "root switch domain ownership",
        [
          Alcotest.test_case "owner true, worker false"
            `Quick
            test_root_switch_ownership_is_domain_local;
          Alcotest.test_case "run_on_owner_domain uninitialized inline"
            `Quick
            test_run_on_owner_domain_inline_when_uninitialized;
          Alcotest.test_case "run_on_owner_domain owner inline"
            `Quick
            test_run_on_owner_domain_inline_on_owner_domain;
          Alcotest.test_case "run_on_owner_domain cross-domain dispatch"
            `Quick
            test_run_on_owner_domain_cross_domain_dispatch;
          Alcotest.test_case "set_switch clears on release"
            `Quick
            test_set_switch_clears_on_release;
          Alcotest.test_case "For_testing.clear_root_switch resets to None"
            `Quick
            test_for_testing_clear_root_switch;
        ] );
    ]
