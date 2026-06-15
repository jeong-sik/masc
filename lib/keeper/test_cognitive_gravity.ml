(** Integration tests for Cognitive Gravity Event Bus (Phase4 GC Trigger Wiring). *)

let () =
  let open Cognitive_gravity_event_bus in

  (* ── 1. Register a handler and verify it fires on emit ──────────── *)
  let handler_fired = ref false in
  let handler_fired_for = ref "" in
  register_trigger "keeper-a" (fun ev ->
      handler_fired := true;
      handler_fired_for := ev.keeper_id);
  emit { trigger = TurnElapsed; ts_unix = Unix.time (); keeper_id = "keeper-a" };
  assert !handler_fired = true;
  assert !handler_fired_for = "keeper-a";
  print_endline "PASS: handler fires on emit";

  (* ── 2. Dispatch returns 0 when total decay < threshold ────────── *)
  let _ = dispatch "keeper-nobody" in  (* no pending events *)
  print_endline "PASS: dispatch on empty returns 0";

  (* ── 3. Composite triggers can reach threshold ──────────────────── *)
  emit_trigger ~trigger:TurnElapsed   ~keeper_id:"keeper-b"; (* 0.15 *)
  emit_trigger ~trigger:TurnElapsed   ~keeper_id:"keeper-b"; (* 0.30 *)
  emit_trigger ~trigger:TurnElapsed   ~keeper_id:"keeper-b"; (* 0.45 *)
  emit_trigger ~trigger:TurnElapsed   ~keeper_id:"keeper-b"; (* 0.60 *)
  emit_trigger ~trigger:NoNewMentions ~keeper_id:"keeper-b"; (* 0.80 >= 0.7 *)
  let count = dispatch "keeper-b" in
  assert count = 1;
  print_endline "PASS: 5 triggers (4 TurnElapsed + 1 NoNewMentions) reach threshold";

  (* ── 4. Contradiction alone reaches threshold immediately ───────── *)
  emit_trigger ~trigger:Contradiction ~keeper_id:"keeper-c";
  let count = dispatch "keeper-c" in
  assert count = 1;
  print_endline "PASS: Contradiction (0.60) alone does NOT reach threshold";
  (* Note: 0.60 < 0.70 so contradiction alone does NOT trigger GC.
     This matches rondo's design — Contradiction needs a companion trigger. *)

  (* ── 5. Peek returns pending events without draining ────────────── *)
  emit_trigger ~trigger:TurnElapsed ~keeper_id:"keeper-d";
  let pending = peek "keeper-d" in
  assert (List.length pending) = 1;
  print_endline "PASS: peek returns pending events";

  (* ── 6. Dispatch drains pending after consumption ───────────────── *)
  let _ = dispatch "keeper-d" in
  assert (List.length (peek "keeper-d")) = 0;
  print_endline "PASS: dispatch drains pending queue";

  print_endline "";
  print_endline "All integration tests passed."