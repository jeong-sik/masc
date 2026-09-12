(* test_keeper_turn_interrupt.ml

   Operator-driven interrupt cancels a live keeper turn by failing the
   turn-scoped Eio switch stored in the registry.

   The turn runs inside its own sub-switch, forked from the test switch, so
   the operator fiber (which calls [Keeper_registry.interrupt_current_turn])
   is NOT inside the switch it fails. This mirrors production, where the
   dashboard handler runs in a different switch than the turn it interrupts
   (see [keeper_agent_run.ml]). Failing a switch from a fiber that runs inside
   it would mark the calling fiber cancelled too and raise [Eio.Cancel.Cancelled]
   at its next suspension point — the nested structure avoids that. *)

open Masc

let failures = ref 0

let check name cond =
  if cond
  then Printf.printf "  ok: %s\n%!" name
  else (
    incr failures;
    Printf.printf "  fail: %s\n%!" name)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          (* The canonical form is the identity module's, not a literal
             prefix: this fixture drifted and the suite has been failing at
             construction, unnoticed because it is not in the CI list. *)
          ("trace_id", `String ("trace-" ^ name));
        ])
  with
  | Ok meta -> meta
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

let temp_base () =
  let d =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-turn-interrupt-%d-%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir d 0o755;
  d
;;

let with_env body =
  let base = temp_base () in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base)
    (fun () ->
      Keeper_registry.For_testing.clear ();
      body ~base)
;;

let test_interrupt_cancels_turn () =
  Printf.printf "Test: operator interrupt cancels a live keeper turn\n%!";
  with_env
  @@ fun ~base ->
  let name = "interrupt-keeper" in
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  let clock = Eio.Stdenv.clock env in
  ignore (Keeper_registry.For_testing.register ~base_path:base name (make_meta name));
  Keeper_registry.mark_turn_started
    ~base_path:base
    ~wake:Keeper_registry.Proactive_tick
    name;
  Eio.Switch.run
  @@ fun sw ->
  let cancelled, set_cancelled = Eio.Promise.create () in
  let registered, set_registered = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    (* [interrupt_current_turn] fails [turn_sw] with [Operator_interrupt];
       when the turn body returns, [Eio.Switch.run turn_sw] re-raises that
       exception at the switch boundary. Production contains it the same way
       ([keeper_agent_run.ml] wraps [Eio.Switch.run @@ fun turn_sw] in a
       [try/with]). Catch it here so the test switch is not poisoned. *)
    (try
       Eio.Switch.run
       @@ fun turn_sw ->
       Keeper_registry.set_turn_switch ~base_path:base name (Some turn_sw);
       Eio.Promise.resolve set_registered ();
       (try
          Eio.Time.sleep clock 10.0;
          Eio.Promise.resolve set_cancelled false
        with
        | Eio.Cancel.Cancelled _ -> Eio.Promise.resolve set_cancelled true)
     with
     | Keeper_registry.Operator_interrupt -> ()
     | Eio.Cancel.Cancelled _ -> ()));
  Eio.Promise.await registered;
  (match Keeper_registry.interrupt_current_turn ~base_path:base name with
   | Keeper_registry.Exact_turn_cancelled turn_id ->
     check "turn_id is 1" (turn_id = 1);
     check "turn fibre cancelled" (Eio.Promise.await cancelled)
   | Keeper_registry.Exact_no_turn_in_flight ->
     check "expected an in-flight turn" false
   | Keeper_registry.Exact_turn_cancel_failed { detail; _ } ->
     Printf.printf "  cancel failed: %s\n%!" detail;
     check "cancellation must not fail here" false);
  let entry = Option.get (Keeper_registry.get ~base_path:base name) in
  check "switch cleared" (Atomic.get entry.current_turn_switch = None)
;;

let test_interrupt_no_turn_is_noop () =
  Printf.printf "Test: operator interrupt is a no-op when idle\n%!";
  with_env
  @@ fun ~base ->
  let name = "idle-keeper" in
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  ignore (Keeper_registry.For_testing.register ~base_path:base name (make_meta name));
  check
    "no in-flight turn"
    (match Keeper_registry.interrupt_current_turn ~base_path:base name with
     | Keeper_registry.Exact_no_turn_in_flight -> true
     | Keeper_registry.Exact_turn_cancelled _
     | Keeper_registry.Exact_turn_cancel_failed _ -> false)
;;

(* An unregistered name is a failed cancellation, not an idle Keeper. Reporting
   it as [Exact_no_turn_in_flight] told an operator the turn was already gone
   when the registry never held it. *)
let test_unknown_keeper_is_a_failure_not_idle () =
  Printf.printf "Test: interrupting an unregistered Keeper reports failure\n%!";
  with_env
  @@ fun ~base ->
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  check
    "unregistered name reports cancel_failed"
    (match
       Keeper_registry.interrupt_current_turn ~base_path:base "never-registered"
     with
     | Keeper_registry.Exact_turn_cancel_failed { turn_id = None; _ } -> true
     | Keeper_registry.Exact_turn_cancel_failed _
     | Keeper_registry.Exact_no_turn_in_flight
     | Keeper_registry.Exact_turn_cancelled _ -> false)
;;

let test_observed_identity_survives_turn_replacement () =
  with_env @@ fun ~base ->
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  let name = "replace-keeper" in
  ignore (Keeper_registry.For_testing.register ~base_path:base name (make_meta name));
  Eio.Switch.run @@ fun old_switch ->
  Keeper_registry.set_turn_switch ~base_path:base name (Some old_switch);
  let old_token = Option.get (Keeper_registry.current_turn_interrupt_token ~base_path:base name) in
  Eio.Switch.run @@ fun successor ->
  Keeper_registry.set_turn_switch ~base_path:base name (Some successor);
  let new_token = Keeper_registry.current_turn_interrupt_token ~base_path:base name in
  check "every switch has a different identity" (new_token <> Some old_token);
  check "stale screen cannot cancel successor"
    (Keeper_registry.interrupt_observed_turn ~base_path:base name ~interrupt_token:old_token
      = Keeper_registry.Observed_turn_changed);
  Keeper_registry.clear_turn_switch_if_current ~base_path:base name old_switch;
  check "old finalizer cannot clear successor"
    (Keeper_registry.current_turn_interrupt_token ~base_path:base name = new_token);
  Keeper_registry.clear_turn_switch_if_current ~base_path:base name successor;
  check "current finalizer clears itself"
    (Keeper_registry.current_turn_interrupt_token ~base_path:base name = None)
;;

let test_observed_interrupt_is_idempotent () =
  with_env @@ fun ~base ->
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  let name = "exact-keeper" in
  ignore (Keeper_registry.For_testing.register ~base_path:base name (make_meta name));
  Eio.Switch.run @@ fun outer ->
  let ready, publish = Eio.Promise.create () in
  let ended, finish = Eio.Promise.create () in
  Eio.Fiber.fork ~sw:outer (fun () ->
    (try Eio.Switch.run (fun turn ->
      Keeper_registry.set_turn_switch ~base_path:base name (Some turn);
      Eio.Promise.resolve publish (Option.get (Keeper_registry.current_turn_interrupt_token ~base_path:base name));
      Eio.Fiber.await_cancel ())
     with exn when Keeper_registry_types.is_operator_interrupt exn -> ());
    Eio.Promise.resolve finish ());
  let interrupt_token = Eio.Promise.await ready in
  check "matching target receives signal"
    (Keeper_registry.interrupt_observed_turn ~base_path:base name ~interrupt_token
      = Keeper_registry.Observed_turn_signalled);
  check "duplicate target cannot signal another turn"
    (Keeper_registry.interrupt_observed_turn ~base_path:base name ~interrupt_token
      = Keeper_registry.Observed_turn_changed);
  Eio.Promise.await ended
;;

let () =
  test_observed_identity_survives_turn_replacement ();
  test_observed_interrupt_is_idempotent ();
  test_interrupt_cancels_turn ();
  test_interrupt_no_turn_is_noop ();
  test_unknown_keeper_is_a_failure_not_idle ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_interrupt checks passed\n%!"
;;
