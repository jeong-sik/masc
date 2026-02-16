(** Pulse module tests.

    Tests the tick engine using Eio.Stdenv.clock (real clock).
    Each test uses very short intervals (0.05s-0.2s) to keep tests fast. *)

open Masc_mcp

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
    ~lifecycle:Pulse.Perpetual
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
    ~lifecycle:Pulse.Perpetual
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
    ~lifecycle:Pulse.Perpetual
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
    ~lifecycle:Pulse.Perpetual
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
    ~lifecycle:Pulse.Perpetual
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
    ~lifecycle:Pulse.Perpetual
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

(* ── Summary ───────────────────────────────────────────────── *)

let () =
  Printf.printf "\nPulse tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
