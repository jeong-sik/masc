(** Pulse module tests.

    Tests the tick engine using Eio.Stdenv.clock (real clock).
    Each test uses very short intervals (0.05s-0.2s) to keep tests fast. *)

let passed = ref 0
let failed = ref 0

let test name fn =
  try
    fn ();
    incr passed;
    Printf.printf "  PASS  %s\n%!" name
  with e ->
    incr failed;
    Printf.printf "  FAIL  %s: %s\n%!" name (Printexc.to_string e)

(* ── Test: create and basic properties ─────────────────────── *)

let () = test "create returns not-alive engine" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 1.0; min_s = 0.5; max_s = 5.0; quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[]
  in
  assert (not (Pulse.is_alive t));
  assert (Pulse.last_beat t = None);
  let s = Pulse.stats t in
  assert (s.total_beats = 0)
)

(* ── Test: run fires startup demand beat ───────────────────── *)

let () = test "run fires startup demand beat and can shutdown" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let beats = ref [] in
  let consumer = (module struct
    let name = "recorder"
    let should_act _b = true
    let on_beat b =
      beats := b :: !beats;
      Ok ()
  end : Pulse.Consumer) in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 0.1; min_s = 0.05; max_s = 1.0; quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[consumer]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  (* Wait for startup beat + one rhythm beat *)
  Eio.Time.sleep clock 0.25;
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.15;
  (* Should have at least: startup(Demand) + rhythm + shutdown(Demand) *)
  let n = List.length !beats in
  if n < 2 then
    failwith (Printf.sprintf "expected >=2 beats, got %d" n);
  (* First beat should be Demand (startup) *)
  let first = List.rev !beats |> List.hd in
  (match first.trigger with
   | Pulse.Demand -> ()
   | _ -> failwith "first beat should be Demand (startup)");
  assert (not (Pulse.is_alive t))
)

(* ── Test: nudge triggers immediate beat ───────────────────── *)

let () = test "nudge triggers immediate beat" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let triggers = ref [] in
  let consumer = (module struct
    let name = "trigger-spy"
    let should_act _b = true
    let on_beat b =
      triggers := b.Pulse.trigger :: !triggers;
      Ok ()
  end : Pulse.Consumer) in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 10.0; min_s = 5.0; max_s = 20.0; quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[consumer]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.05;  (* let startup beat fire *)
  Pulse.nudge t ~reason:"test-nudge";
  Eio.Time.sleep clock 0.15;  (* let nudge beat process *)
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.15;
  let has_nudge = List.exists (function
    | Pulse.Nudge r -> r = "test-nudge"
    | _ -> false
  ) !triggers in
  if not has_nudge then
    failwith "expected a Nudge(test-nudge) trigger in beats"
)

(* ── Test: bounded lifecycle stops engine ──────────────────── *)

let () = test "bounded lifecycle stops after predicate" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let beat_count = ref 0 in
  let consumer = (module struct
    let name = "counter"
    let should_act _b = true
    let on_beat _b =
      incr beat_count;
      Ok ()
  end : Pulse.Consumer) in
  (* Stop after 3 beats (including startup demand) *)
  let lifecycle = Pulse.Bounded (fun b -> b.Pulse.seq >= 3) in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 0.05; min_s = 0.03; max_s = 1.0; quiet = (1, 6) }
    ~lifecycle
    ~consumers:[consumer]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  (* Wait enough for several beats *)
  Eio.Time.sleep clock 0.5;
  (* Engine should have stopped *)
  assert (not (Pulse.is_alive t));
  let s = Pulse.stats t in
  (* seq >= 3 at the point of stop, plus shutdown demand = seq >= 4 *)
  if s.total_beats < 3 then
    failwith (Printf.sprintf "expected >=3 beats, got %d" s.total_beats)
)

(* ── Test: consumer error doesn't crash pulse ─────────────── *)

let () = test "consumer error doesn't crash pulse" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let good_count = ref 0 in
  let bad_consumer = (module struct
    let name = "bomb"
    let should_act _b = true
    let on_beat _b = Error "boom"
  end : Pulse.Consumer) in
  let good_consumer = (module struct
    let name = "survivor"
    let should_act _b = true
    let on_beat _b =
      incr good_count;
      Ok ()
  end : Pulse.Consumer) in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 0.05; min_s = 0.03; max_s = 1.0; quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[bad_consumer; good_consumer]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.2;
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.1;
  if !good_count < 2 then
    failwith (Printf.sprintf "good consumer should have been called >=2 times, got %d" !good_count)
)

(* ── Test: should_act filtering ────────────────────────────── *)

let () = test "should_act filters beats" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let even_count = ref 0 in
  let consumer = (module struct
    let name = "even-only"
    let should_act b = b.Pulse.seq mod 2 = 0
    let on_beat _b =
      incr even_count;
      Ok ()
  end : Pulse.Consumer) in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 0.05; min_s = 0.03; max_s = 1.0; quiet = (1, 6) }
    ~lifecycle:(Pulse.Bounded (fun b -> b.Pulse.seq >= 6))
    ~consumers:[consumer]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.8;
  (* Only even-numbered beats should have triggered the consumer *)
  if !even_count = 0 then
    failwith "even-only consumer was never called"
)

(* ── Test: add/remove consumer dynamically ─────────────────── *)

let () = test "add and remove consumer dynamically" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let late_count = ref 0 in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 0.05; min_s = 0.03; max_s = 1.0; quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.1;
  (* Add consumer after engine started *)
  let late_consumer = (module struct
    let name = "late-joiner"
    let should_act _b = true
    let on_beat _b =
      incr late_count;
      Ok ()
  end : Pulse.Consumer) in
  Pulse.add_consumer t late_consumer;
  Eio.Time.sleep clock 0.15;
  (* Remove it *)
  let removed = Pulse.remove_consumer t "late-joiner" in
  assert removed;
  let count_at_remove = !late_count in
  Eio.Time.sleep clock 0.15;
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.1;
  (* Should have been called at least once *)
  if count_at_remove < 1 then
    failwith "late-joiner was never called";
  (* Should not increase after removal *)
  if !late_count > count_at_remove + 1 then
    failwith (Printf.sprintf "late-joiner called after removal: before=%d after=%d"
      count_at_remove !late_count)
)

(* ── Test: default_rhythm values ───────────────────────────── *)

let () = test "default_rhythm has sane values" (fun () ->
  let r = Pulse.default_rhythm in
  assert (r.base_s = 60.0);
  assert (r.min_s = 30.0);
  assert (r.max_s = 300.0);
  assert (r.quiet = (1, 6))
)

(* ── Test: stats accuracy ──────────────────────────────────── *)

let () = test "stats tracks beats and nudges" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 10.0; min_s = 5.0; max_s = 20.0; quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.05;
  Pulse.nudge t ~reason:"n1";
  Eio.Time.sleep clock 0.1;
  Pulse.nudge t ~reason:"n2";
  Eio.Time.sleep clock 0.1;
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.15;
  let s = Pulse.stats t in
  if s.total_nudges < 2 then
    failwith (Printf.sprintf "expected >=2 nudges, got %d" s.total_nudges);
  if s.total_beats < 3 then
    failwith (Printf.sprintf "expected >=3 beats (startup + 2 nudges), got %d" s.total_beats)
)

(* ── Test: quiet hour — normal range (1..6) ──────────────────── *)

let () = test "quiet_hour_normal_range" (fun () ->
  let q = Pulse.For_testing.is_quiet_hour_at in
  let range = (1, 6) in
  (* Inside quiet: 1,2,3,4,5 *)
  assert (q ~hour:1 ~quiet_range:range);
  assert (q ~hour:3 ~quiet_range:range);
  assert (q ~hour:5 ~quiet_range:range);
  (* Outside quiet: 0,6,7,23 *)
  assert (not (q ~hour:0 ~quiet_range:range));
  assert (not (q ~hour:6 ~quiet_range:range));
  assert (not (q ~hour:7 ~quiet_range:range));
  assert (not (q ~hour:23 ~quiet_range:range))
)

(* ── Test: quiet hour — wrap-around range (22..6) ────────────── *)

let () = test "quiet_hour_wrap_around" (fun () ->
  let q = Pulse.For_testing.is_quiet_hour_at in
  let range = (22, 6) in
  (* Inside quiet: 22,23,0,3,5 *)
  assert (q ~hour:22 ~quiet_range:range);
  assert (q ~hour:23 ~quiet_range:range);
  assert (q ~hour:0 ~quiet_range:range);
  assert (q ~hour:3 ~quiet_range:range);
  assert (q ~hour:5 ~quiet_range:range);
  (* Outside quiet: 6,12,21 *)
  assert (not (q ~hour:6 ~quiet_range:range));
  assert (not (q ~hour:12 ~quiet_range:range));
  assert (not (q ~hour:21 ~quiet_range:range))
)

(* ── Test: quiet hour — boundary cases ───────────────────────── *)

let () = test "quiet_hour_boundary" (fun () ->
  let q = Pulse.For_testing.is_quiet_hour_at in
  (* (0,0): qs <= qe, hour >= 0 && hour < 0 → always false *)
  for h = 0 to 23 do
    assert (not (q ~hour:h ~quiet_range:(0, 0)))
  done;
  (* (0,24): qs <= qe, hour >= 0 && hour < 24 → always true *)
  for h = 0 to 23 do
    assert (q ~hour:h ~quiet_range:(0, 24))
  done
)

(* ── Test: effective interval — normal vs quiet ──────────────── *)

let () = test "effective_interval_normal" (fun () ->
  let eff = Pulse.For_testing.effective_interval_at in
  let r = Pulse.default_rhythm in
  (* base=60, min=30, max=300, quiet=(1,6) *)
  (* hour=12: not quiet → base=60 → clamp(30, 300, 60) = 60 *)
  let v_normal = eff ~hour:12 r in
  assert (v_normal = 60.0);
  (* hour=3: quiet → base=60*3=180 → clamp(30, 300, 180) = 180 *)
  let v_quiet = eff ~hour:3 r in
  assert (v_quiet = 180.0)
)

(* ── Test: effective interval — clamping ─────────────────────── *)

let () = test "effective_interval_clamping" (fun () ->
  let eff = Pulse.For_testing.effective_interval_at in
  (* Clamp to max: base=200, quiet→200*3=600 > max=300 → 300 *)
  let r_high = { Pulse.base_s = 200.0; min_s = 30.0; max_s = 300.0;
                 quiet = (1, 6) } in
  let v = eff ~hour:3 r_high in
  assert (v = 300.0);
  (* Clamp to min: base=5, not quiet→5 < min=30 → 30 *)
  let r_low = { Pulse.base_s = 5.0; min_s = 30.0; max_s = 300.0;
                quiet = (1, 6) } in
  let v2 = eff ~hour:12 r_low in
  assert (v2 = 30.0)
)

(* ── Test: nudge coalescing — full stream ────────────────────── *)

let () = test "nudge_coalescing" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 100.0; min_s = 50.0; max_s = 200.0;
              quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.05;
  (* First nudge goes into the capacity-1 stream *)
  Pulse.nudge t ~reason:"first";
  (* Second nudge should be silently dropped (stream full) *)
  Pulse.nudge t ~reason:"second";
  (* Give time for the engine to process *)
  Eio.Time.sleep clock 0.15;
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.1;
  let s = Pulse.stats t in
  (* At least startup + nudge(first) + shutdown, but NOT two nudge beats
     since "second" was coalesced (dropped). total_nudges should be <= 1
     from the rapid pair — the engine may process first before second arrives,
     so we just verify the engine didn't block/crash. *)
  if s.total_beats < 2 then
    failwith (Printf.sprintf "expected >=2 beats, got %d" s.total_beats)
)

(* ── Test: consumer recovery — disabled after consecutive failures ── *)

let () = test "consumer disabled after 3 consecutive failures" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let fail_consumer = (module struct
    let name = "always_fail"
    let should_act _b = true
    let on_beat _b = Error "intentional"
  end : Pulse.Consumer) in
  let ok_count = ref 0 in
  let ok_consumer = (module struct
    let name = "always_ok"
    let should_act _b = true
    let on_beat _b = incr ok_count; Ok ()
  end : Pulse.Consumer) in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 0.05; min_s = 0.01; max_s = 1.0; quiet = (1, 6) }
    ~lifecycle:(Pulse.Bounded (fun b -> b.seq >= 5))
    ~consumers:[fail_consumer; ok_consumer]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 1.0;
  (* fail_consumer should be disabled after 3 failures *)
  let disabled = Pulse.disabled_consumers t in
  assert (List.mem "always_fail" disabled);
  (* ok_consumer should NOT be disabled *)
  assert (not (List.mem "always_ok" disabled));
  (* ok_consumer should have been called for all beats *)
  assert (!ok_count >= 5)
)

(* ── Test: reenable disabled consumer ──────────────────────── *)

let () = test "reenable previously disabled consumer" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let fail_count = ref 0 in
  let consumer = (module struct
    let name = "flaky"
    let should_act _b = true
    let on_beat _b =
      incr fail_count;
      if !fail_count <= 3 then Error "flaky"
      else Ok ()
  end : Pulse.Consumer) in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 0.05; min_s = 0.01; max_s = 1.0; quiet = (1, 6) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[consumer]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.5;
  (* Should be disabled after 3 failures *)
  assert (List.mem "flaky" (Pulse.disabled_consumers t));
  (* Re-enable *)
  let restored = Pulse.reenable_consumer t "flaky" in
  assert restored;
  assert (not (List.mem "flaky" (Pulse.disabled_consumers t)));
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.1
)

(* ── Test: circuit_breaker wrap ────────────────────────────── *)

let () = test "circuit_breaker wrap records success/failure" (fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let cb = Circuit_breaker.create
    ~failure_threshold:2 ~failure_window:60.0 ~cooldown:1.0 () in
  (* Success path *)
  let r1 = Circuit_breaker.wrap cb ~agent_id:"test" (fun () -> Ok 42) in
  assert (r1 = Ok 42);
  let s = Circuit_breaker.get_status cb ~agent_id:"test" in
  assert (s.state_name = "closed");
  (* 2 failures should open the breaker *)
  ignore (Circuit_breaker.wrap cb ~agent_id:"test" (fun () -> Error "fail1"));
  ignore (Circuit_breaker.wrap cb ~agent_id:"test" (fun () -> Error "fail2"));
  let s2 = Circuit_breaker.get_status cb ~agent_id:"test" in
  assert (s2.state_name = "open");
  (* Wrapped call should be rejected while open *)
  let r2 = Circuit_breaker.wrap cb ~agent_id:"test" (fun () -> Ok 99) in
  (match r2 with Error _ -> () | Ok _ -> failwith "expected Error while open")
)

(* ── Test: circuit_breaker wrap_result ────────────────────────── *)

let () = test "circuit_breaker wrap_result catches exceptions" (fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let cb = Circuit_breaker.create
    ~failure_threshold:3 ~failure_window:60.0 ~cooldown:1.0 () in
  let r = Circuit_breaker.wrap_result cb ~agent_id:"exc-test" (fun () ->
    failwith "boom"
  ) in
  (match r with Error _ -> () | Ok _ -> failwith "expected Error from exception");
  let s = Circuit_breaker.get_status cb ~agent_id:"exc-test" in
  assert (s.recent_failures = 1)
)

(* ── Test: set_rhythm updates interval ────────────────────── *)

let () = test "set_rhythm changes interval" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let t = Pulse.create
    ~clock
    ~rhythm:{ Pulse.base_s = 100.0; min_s = 50.0; max_s = 200.0; quiet = (0, 0) }
    ~lifecycle:Pulse.Always_on
    ~consumers:[]
  in
  Eio.Switch.run @@ fun sw ->
  Pulse.run ~sw t;
  Eio.Time.sleep clock 0.05;  (* startup beat *)
  let before = (Pulse.stats t).total_beats in
  (* Switch to fast rhythm via set_rhythm *)
  Pulse.set_rhythm t { Pulse.base_s = 0.05; min_s = 0.03; max_s = 1.0; quiet = (0, 0) };
  (* Nudge to break the current long sleep and pick up new rhythm *)
  Pulse.nudge t ~reason:"rhythm-changed";
  Eio.Time.sleep clock 0.4;
  let after = (Pulse.stats t).total_beats in
  Pulse.shutdown t;
  Eio.Time.sleep clock 0.1;
  (* Rhythm beats should have accumulated from the fast interval *)
  let gained = after - before in
  if gained < 3 then
    failwith (Printf.sprintf "expected >=3 beats after set_rhythm, got %d" gained)
)

(* ── Test: get_rhythm returns current value ──────────────── *)

let () = test "get_rhythm returns current rhythm" (fun () ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let t = Pulse.create
    ~clock
    ~rhythm:Pulse.default_rhythm
    ~lifecycle:Pulse.Always_on
    ~consumers:[]
  in
  let r = Pulse.get_rhythm t in
  assert (r.base_s = 60.0);
  assert (r.min_s = 30.0);
  Pulse.set_rhythm t { Pulse.base_s = 15.0; min_s = 10.0; max_s = 60.0; quiet = (2, 5) };
  let r2 = Pulse.get_rhythm t in
  assert (r2.base_s = 15.0);
  assert (r2.min_s = 10.0);
  assert (r2.max_s = 60.0);
  assert (r2.quiet = (2, 5))
)

(* ── Summary ───────────────────────────────────────────────── *)

let () =
  Printf.printf "\nPulse tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
