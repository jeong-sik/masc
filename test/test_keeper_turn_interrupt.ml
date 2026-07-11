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

let test_shutdown_interrupt_persists_typed_settlement () =
  Printf.printf "Test: shutdown interrupt persists typed turn settlement\n%!";
  with_env
  @@ fun ~base ->
  let name = "shutdown-interrupt-keeper" in
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  let config = Workspace.default_config base in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  let unlaunched_name = "shutdown-unlaunched-keeper" in
  let unlaunched =
    Keeper_registry.register_offline
      ~base_path:base
      unlaunched_name
      (make_meta unlaunched_name)
  in
  check
    "shutdown settles an unlaunched physical lane"
    (Keeper_registry.settle_unlaunched_fiber_exit unlaunched);
  check
    "unlaunched physical exit resolves its join promise"
    (Option.is_some (Eio.Promise.peek unlaunched.fiber_exited_p));
  check
    "a settled unlaunched lane cannot launch later"
    (match Keeper_registry.claim_fiber_launch unlaunched with
     | Keeper_registry.Fiber_launch_already_exited -> true
     | Keeper_registry.Fiber_launch_claimed
     | Keeper_registry.Fiber_launch_already_running -> false);
  let meta = make_meta name in
  let entry = Keeper_registry.register ~base_path:base name meta in
  check
    "first shutdown transaction claim succeeds"
    (Keeper_registry.try_claim_shutdown_transaction entry);
  check
    "concurrent shutdown transaction claim is rejected"
    (not (Keeper_registry.try_claim_shutdown_transaction entry));
  Keeper_registry.release_shutdown_transaction entry;
  check
    "shutdown transaction claim is retryable after release"
    (Keeper_registry.try_claim_shutdown_transaction entry);
  Keeper_registry.release_shutdown_transaction entry;
  ignore (Keeper_registry.begin_shutdown entry : Keeper_registry.shutdown_begin_result);
  Keeper_registry.mark_turn_started
    ~base_path:base
    ~wake:Keeper_registry.Proactive_tick
    name;
  Eio.Switch.run
  @@ fun sw ->
  let registered, set_registered = Eio.Promise.create () in
  let cancelled, set_cancelled = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    (try
       Eio.Switch.run
       @@ fun turn_sw ->
       Eio.Switch.on_release turn_sw (fun () ->
         Keeper_registry.clear_turn_switch ~base_path:base name);
       Keeper_registry.set_turn_switch ~base_path:base name (Some turn_sw);
       Eio.Promise.resolve set_registered ();
       Eio.Time.sleep (Eio.Stdenv.clock env) 10.0
     with
     | Keeper_registry.Shutdown_interrupt
     | Eio.Cancel.Cancelled Keeper_registry.Shutdown_interrupt ->
       Eio.Promise.resolve set_cancelled ()));
  Eio.Promise.await registered;
  Eio.Promise.await cancelled;
  let turn_id =
    match Keeper_registry.shutdown_turn_settlement entry with
    | Some (Keeper_shutdown_types.Awaiting_interrupted_turn { turn_id }) ->
      check "shutdown turn_id is 1" (turn_id = 1);
      turn_id
    | Some
        (Keeper_shutdown_types.No_interrupted_turn
        | Keeper_shutdown_types.Interrupted_turn_persisted _
        | Keeper_shutdown_types.Interrupted_turn_persist_failed _)
    | None ->
      check "shutdown turn is awaiting settlement" false;
      1
  in
  let record =
    Keeper_shutdown_types.make_interrupted_turn
      ~keeper_name:name
      ~trace_id:meta.runtime.trace_id
      ~turn_id
      ~current_task_id:None
      ~interrupted_at:(Time_compat.now ())
      ~committed_mutating_tools:[]
      ~event_bus_integrity_error:None
  in
  let ambiguous_record =
    Keeper_shutdown_types.make_interrupted_turn
      ~keeper_name:name
      ~trace_id:meta.runtime.trace_id
      ~turn_id
      ~current_task_id:None
      ~interrupted_at:(Time_compat.now ())
      ~committed_mutating_tools:[ "fixture_mutation" ]
      ~event_bus_integrity_error:None
  in
  check
    "committed mutation yields an explicit ambiguous-result record"
    (match ambiguous_record.outcome with
     | Keeper_shutdown_types.Ambiguous_result
         { committed_mutating_tools = [ _ ]; event_bus_integrity_error = None } ->
       true
     | Keeper_shutdown_types.Ambiguous_result _
     | Keeper_shutdown_types.Continuation_required -> false);
  (match Keeper_shutdown_record.persist ~config record with
   | Error error ->
     check ("shutdown record persisted: " ^ error) false
   | Ok persisted ->
     check "shutdown record exists" (Fs_compat.file_exists persisted.path);
     (match Keeper_registry.record_shutdown_turn_persisted entry persisted with
      | Error error ->
        check
          ("shutdown registry settlement committed: "
           ^ Keeper_registry.shutdown_state_error_to_string error)
          false
      | Ok () ->
        check
          "shutdown registry points at durable record"
          (match Keeper_registry.shutdown_turn_settlement entry with
           | Some
               (Keeper_shutdown_types.Interrupted_turn_persisted
                  { path; record = _ }) ->
             String.equal path persisted.path
           | Some
               (Keeper_shutdown_types.No_interrupted_turn
               | Keeper_shutdown_types.Awaiting_interrupted_turn _
               | Keeper_shutdown_types.Interrupted_turn_persist_failed _)
           | None -> false)))
;;

let () =
  test_interrupt_cancels_turn ();
  test_interrupt_no_turn_is_noop ();
  test_shutdown_interrupt_persists_typed_settlement ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_interrupt checks passed\n%!"
;;
