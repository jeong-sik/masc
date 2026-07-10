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
          ("agent_name", `String ("agent-" ^ name));
          ("trace_id", `String ("trace-" ^ name));
          ("allowed_paths", `List [ `String "*" ]);
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
      Keeper_registry.clear ();
      Keeper_turn_admission.For_testing.reset ();
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
  ignore (Keeper_registry.register ~base_path:base name (make_meta name));
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
   | `Cancelled turn_id ->
     check "turn_id is 1" (turn_id = 1);
     check "turn fibre cancelled" (Eio.Promise.await cancelled)
   | `No_turn_in_flight -> check "expected an in-flight turn" false);
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
  ignore (Keeper_registry.register ~base_path:base name (make_meta name));
  check
    "no in-flight turn"
    (match Keeper_registry.interrupt_current_turn ~base_path:base name with
     | `Cancelled _ -> false
     | `No_turn_in_flight -> true)
;;

let () =
  test_interrupt_cancels_turn ();
  test_interrupt_no_turn_is_noop ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_interrupt checks passed\n%!"
;;
