(** Unit tests for Cognitive_gravity_event_bus (Phase4 GC trigger registry + dispatch). *)

open Masc.Cognitive_gravity_event_bus

let approx_eq a b = Float.abs (a -. b) <= 0.0001

(* ── Registry lifecycle ───────────────────────────────── *)

let test_empty_registry_dispatch_returns_empty () =
  (* No triggers registered → dispatch returns [] *)
  let events = dispatch () in
  Alcotest.(check int) "empty dispatch yields zero events" 0 (List.length events)

let test_register_and_dispatch_turn_elapsed () =
  let fired = ref false in
  let handler ev = fired := true in
  let trigger = TurnElapsed { age = 10; min_age = 3 } in
  register_trigger trigger ~handler;
  let events = dispatch () in
  Alcotest.(check bool) "handler was invoked" true !fired;
  Alcotest.(check int) "one event returned" 1 (List.length events);
  let ev = List.hd events in
  Alcotest.(check bool) "trigger variant preserved"
    (match ev.trigger with TurnElapsed _ -> true | _ -> false)
    true;
  Alcotest.(check bool) "delta is default for TurnElapsed"
    (approx_eq ev.delta 0.02) true

let test_register_and_dispatch_no_new_mentions () =
  let fired = ref false in
  let handler ev = fired := true in
  let trigger = NoNewMentions { turns = 5; min_idle = 2 } in
  register_trigger trigger ~handler;
  let events = dispatch () in
  Alcotest.(check bool) "handler was invoked" true !fired;
  let ev = List.hd events in
  Alcotest.(check bool) "default delta for NoNewMentions"
    (approx_eq ev.delta 0.05) true

let test_register_and_dispatch_contradiction () =
  let captured = ref None in
  let handler ev = captured := Some ev.target_fact_ids in
  let trigger = Contradiction { fact_id = "fact-42"; staleness = 3.5 } in
  register_trigger trigger ~handler;
  let _events = dispatch () in
  match !captured with
  | None -> Alcotest.fail "handler not invoked"
  | Some ids ->
    Alcotest.(check (list string))
      "target fact_ids contains fact-42" [ "fact-42" ] ids

let test_manual_decay_rate_passed_through () =
  let fired = ref false in
  let handler ev = fired := true in
  let rate = 0.33 in
  let trigger = ManualDecay { fact_ids = [ "a"; "b" ]; rate } in
  register_trigger trigger ~handler;
  let events = dispatch () in
  let ev = List.hd events in
  Alcotest.(check bool) "manual handler invoked" true !fired;
  Alcotest.(check bool) "manual delta equals rate"
    (approx_eq ev.delta rate) true;
  Alcotest.(check (list string))
    "target fact_ids preserved" [ "a"; "b" ] ev.target_fact_ids

let test_multiple_triggers_all_fire () =
  let counter = ref 0 in
  let h _ = incr counter in
  register_trigger (TurnElapsed { age = 1; min_age = 0 }) ~handler:h;
  register_trigger (NoNewMentions { turns = 3; min_idle = 1 }) ~handler:h;
  register_trigger (Contradiction { fact_id = "f1"; staleness = 1.0 }) ~handler:h;
  let events = dispatch () in
  Alcotest.(check int) "counter matches event count" 3 !counter;
  Alcotest.(check int) "three events returned" 3 (List.length events)

(* ── Emit ─────────────────────────────────────────────── *)

let test_emit_calls_registered_handler () =
  let captured = ref None in
  let handler ev = captured := Some ev in
  let trigger = TurnElapsed { age = 5; min_age = 1 } in
  register_trigger trigger ~handler;
  let custom_event = {
    trigger;
    target_fact_ids = [ "manual" ];
    delta = 0.99;
    applied_at_turn = 0;
  } in
  emit custom_event;
  match !captured with
  | None -> Alcotest.fail "emit handler not invoked"
  | Some ev ->
    Alcotest.(check bool) "delta preserved on emit"
      (approx_eq ev.delta 0.99) true;
    Alcotest.(check (list string))
      "target ids from emit" [ "manual" ] ev.target_fact_ids

(* ── Scalars ──────────────────────────────────────────── *)

let test_default_delta_values () =
  Alcotest.(check bool) "TurnElapsed default delta = 0.02"
    (approx_eq (default_delta (TurnElapsed { age = 1; min_age = 0 })) 0.02) true;
  Alcotest.(check bool) "NoNewMentions default delta = 0.05"
    (approx_eq (default_delta (NoNewMentions { turns = 1; min_idle = 0 })) 0.05) true;
  Alcotest.(check bool) "Contradiction default delta = 0.10"
    (approx_eq (default_delta (Contradiction { fact_id = ""; staleness = 0.0 })) 0.10) true

(* ── Test registration ────────────────────────────────── *)

let () =
  Alcotest.run "Cognitive_gravity_event_bus"
    [ "registry", [
        Alcotest.test_case "empty dispatch yields []" `Quick test_empty_registry_dispatch_returns_empty;
        Alcotest.test_case "register + dispatch TurnElapsed" `Quick test_register_and_dispatch_turn_elapsed;
        Alcotest.test_case "register + dispatch NoNewMentions" `Quick test_register_and_dispatch_no_new_mentions;
        Alcotest.test_case "register + dispatch Contradiction" `Quick test_register_and_dispatch_contradiction;
        Alcotest.test_case "ManualDecay rate passed through" `Quick test_manual_decay_rate_passed_through;
        Alcotest.test_case "multiple triggers all fire" `Quick test_multiple_triggers_all_fire;
      ];
      "emit", [
        Alcotest.test_case "emit calls registered handler" `Quick test_emit_calls_registered_handler;
      ];
      "scalars", [
        Alcotest.test_case "default_delta values" `Quick test_default_delta_values;
      ];
    ]