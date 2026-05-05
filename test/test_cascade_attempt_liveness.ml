(** Tests for [Cascade_attempt_liveness] (RFC-0022 PR-1/4).

    Mirrors RFC §4.5 decision table exhaustively + property tests
    from §8 that are decidable on the pure FSM (the caller-wiring
    properties — L1 lockstep, cancellation cleanup — land with PR-2). *)

open Masc_mcp
module L = Cascade_attempt_liveness
module C = L.Stream_chunk

let check_state =
  Alcotest.testable
    (fun fmt -> function
      | L.Awaiting { started_at } ->
          Format.fprintf fmt "Awaiting(started_at=%g)" started_at
      | L.Streaming { started_at; last_chunk_at } ->
          Format.fprintf fmt "Streaming(started_at=%g, last_chunk_at=%g)"
            started_at last_chunk_at
      | L.Failed f ->
          Format.fprintf fmt "Failed(%s)" (L.failure_kind_label f)
      | L.Success -> Format.fprintf fmt "Success")
    ( = )

let check_output =
  Alcotest.testable
    (fun fmt -> function
      | L.Continue -> Format.fprintf fmt "Continue"
      | L.Outcome f ->
          Format.fprintf fmt "Outcome(%s)" (L.failure_kind_label f)
      | L.Completed -> Format.fprintf fmt "Completed")
    ( = )

let budget = L.cloud_fast (* 30/20/180 *)

(* ──────────────────────── §4.5 decision table ──────────────────────── *)

let test_awaiting_chunk_any_to_streaming () =
  let s = L.initial ~started_at:0.0 in
  let s', o = L.step budget s (L.Chunk (C.Answer_delta, 5.0)) in
  Alcotest.check check_state "transition"
    (L.Streaming { started_at = 0.0; last_chunk_at = 5.0 }) s';
  Alcotest.check check_output "continue" L.Continue o

let test_awaiting_ttft_kills () =
  let s = L.initial ~started_at:0.0 in
  let s', o = L.step budget s (L.Tick 30.0) in
  Alcotest.check check_state "Failed No_first_token"
    (L.Failed L.No_first_token) s';
  Alcotest.check check_output "Outcome No_first_token"
    (L.Outcome L.No_first_token) o

let test_awaiting_just_under_ttft_continues () =
  let s = L.initial ~started_at:0.0 in
  let s', o = L.step budget s (L.Tick 29.999) in
  Alcotest.check check_state "still awaiting" s s';
  Alcotest.check check_output "continue" L.Continue o

let test_awaiting_provider_error () =
  let s = L.initial ~started_at:0.0 in
  let s', o = L.step budget s (L.Provider_wire_error "HTTP 502") in
  (match s' with
   | L.Failed (L.Provider_error "HTTP 502") -> ()
   | _ -> Alcotest.fail "expected Failed Provider_error \"HTTP 502\"");
  (match o with
   | L.Outcome (L.Provider_error "HTTP 502") -> ()
   | _ -> Alcotest.fail "expected Outcome Provider_error \"HTTP 502\"")

let test_streaming_chunk_advances_clock () =
  let s = L.Streaming { started_at = 0.0; last_chunk_at = 5.0 } in
  let s', o = L.step budget s (L.Chunk (C.Answer_delta, 12.0)) in
  Alcotest.check check_state "last_chunk_at advanced"
    (L.Streaming { started_at = 0.0; last_chunk_at = 12.0 }) s';
  Alcotest.check check_output "continue" L.Continue o

let test_streaming_inter_chunk_idle_kills () =
  let s = L.Streaming { started_at = 0.0; last_chunk_at = 5.0 } in
  let s', o = L.step budget s (L.Tick 25.0) in
  Alcotest.check check_state "Failed Inter_chunk_idle"
    (L.Failed L.Inter_chunk_idle) s';
  Alcotest.check check_output "Outcome Inter_chunk_idle"
    (L.Outcome L.Inter_chunk_idle) o

let test_streaming_wall_exceeded_kills () =
  let s = L.Streaming { started_at = 0.0; last_chunk_at = 179.0 } in
  let s', o = L.step budget s (L.Tick 180.0) in
  Alcotest.check check_state "Failed Wall_exceeded"
    (L.Failed L.Wall_exceeded) s';
  Alcotest.check check_output "Outcome Wall_exceeded"
    (L.Outcome L.Wall_exceeded) o

let test_streaming_inter_chunk_wins_over_wall () =
  (* L2 (no double kill) — when both inter-chunk and wall expire on
     the same tick, the more specific kill class wins. *)
  let s = L.Streaming { started_at = 0.0; last_chunk_at = 100.0 } in
  let s', _ = L.step budget s (L.Tick 200.0) in
  Alcotest.check check_state "inter-chunk preferred"
    (L.Failed L.Inter_chunk_idle) s'

let test_streaming_done_to_success () =
  let s = L.Streaming { started_at = 0.0; last_chunk_at = 5.0 } in
  let s', o = L.step budget s (L.Chunk (C.Done, 6.0)) in
  Alcotest.check check_state "Success" L.Success s';
  Alcotest.check check_output "Completed" L.Completed o

let test_awaiting_done_to_success () =
  (* Edge case: provider sends Done with no preceding tokens. Caller
     accept predicate decides if the empty body is acceptable; the
     liveness FSM only tracks motion. *)
  let s = L.initial ~started_at:0.0 in
  let s', o = L.step budget s (L.Chunk (C.Done, 0.5)) in
  Alcotest.check check_state "Success" L.Success s';
  Alcotest.check check_output "Completed" L.Completed o

let test_streaming_provider_error () =
  let s = L.Streaming { started_at = 0.0; last_chunk_at = 5.0 } in
  let s', o = L.step budget s (L.Provider_wire_error "ECONNRESET") in
  (match s' with
   | L.Failed (L.Provider_error "ECONNRESET") -> ()
   | _ -> Alcotest.fail "expected Failed Provider_error \"ECONNRESET\"");
  (match o with
   | L.Outcome (L.Provider_error "ECONNRESET") -> ()
   | _ -> Alcotest.fail "expected Outcome Provider_error \"ECONNRESET\"")

let test_failed_state_is_absorbing () =
  let s = L.Failed L.No_first_token in
  let s', o = L.step budget s (L.Chunk (C.Answer_delta, 100.0)) in
  Alcotest.check check_state "stays Failed" s s';
  Alcotest.check check_output "Continue" L.Continue o

let test_success_state_is_absorbing () =
  let s = L.Success in
  let s', o = L.step budget s (L.Tick 1000.0) in
  Alcotest.check check_state "stays Success" s s';
  Alcotest.check check_output "Continue" L.Continue o

(* ──────────────────────── §8 property tests ──────────────────────── *)

(* §8.4 Thinking protection — adaptive-reasoning model emits thinking
   tokens every 5s for 600s under cloud_thinking profile (60/30/300).
   Hits wall at 300s but never inter-chunk. *)
let test_thinking_protection_hits_wall_only () =
  let b = L.cloud_thinking in
  let s = ref (L.initial ~started_at:0.0) in
  let killed_by = ref None in
  let t = ref 0.0 in
  while not (L.is_terminal !s) && !t < 600.0 do
    t := !t +. 5.0;
    (* chunk arrives at t *)
    let s', _ = L.step b !s (L.Chunk (C.Thinking_delta, !t)) in
    s := s';
    (* tick same instant *)
    let s'', o = L.step b !s (L.Tick !t) in
    s := s'';
    (match o with
     | L.Outcome f -> killed_by := Some f
     | _ -> ())
  done;
  match !killed_by with
  | Some L.Wall_exceeded ->
      (* Expected: wall at 300s + small overshoot due to 5s tick grain. *)
      Alcotest.(check bool) "killed by wall, not inter-chunk" true true
  | Some L.Inter_chunk_idle ->
      Alcotest.fail "thinking stream killed by inter-chunk — protection failed"
  | Some other ->
      Alcotest.failf "unexpected kill class: %s"
        (L.failure_kind_label other)
  | None ->
      (* Wall is 300s, loop runs to 600s — must have fired. *)
      Alcotest.fail "wall never fired"

(* §8.5 Hung-first-byte — provider holds connection without any
   chunks. Killed at TTFT_MAX exactly. *)
let test_hung_first_byte_kills_at_ttft () =
  let b = L.cloud_fast in (* ttft_max = 30 *)
  let s = ref (L.initial ~started_at:0.0) in
  let kill_t = ref None in
  let t = ref 0.0 in
  while not (L.is_terminal !s) && !t < 60.0 do
    t := !t +. 1.0;
    let s', o = L.step b !s (L.Tick !t) in
    s := s';
    (match o with
     | L.Outcome _ -> kill_t := Some !t
     | _ -> ())
  done;
  match !kill_t with
  | Some k ->
      Alcotest.(check bool) "kill at ttft (±1s tick grain)" true
        (Float.abs (k -. 30.0) <= 1.0)
  | None -> Alcotest.fail "TTFT never fired"

(* §8.6 Mid-stream stall — 3 chunks then silence. Killed at
   last_chunk_at + IDLE_MAX. *)
let test_mid_stream_stall_kills_at_idle () =
  let b = L.cloud_fast in (* inter_chunk_max = 20 *)
  let s = ref (L.initial ~started_at:0.0) in
  (* Three chunks at t=1, 2, 3 *)
  List.iter (fun t ->
    let s', _ = L.step b !s (L.Chunk (C.Answer_delta, t)) in
    s := s'
  ) [ 1.0; 2.0; 3.0 ];
  (* Tick forward in 1s grain. *)
  let kill_t = ref None in
  let t = ref 3.0 in
  while not (L.is_terminal !s) && !t < 30.0 do
    t := !t +. 1.0;
    let s', o = L.step b !s (L.Tick !t) in
    s := s';
    (match o with
     | L.Outcome _ -> kill_t := Some !t
     | _ -> ())
  done;
  match !kill_t with
  | Some k ->
      (* last_chunk_at = 3.0, idle_max = 20, expected kill at t = 23. *)
      Alcotest.(check bool) "kill at last_chunk_at + idle_max (±1s)" true
        (Float.abs (k -. 23.0) <= 1.0)
  | None -> Alcotest.fail "Inter_chunk_idle never fired"

(* §8.7 Wall backstop — provider streams a token every (idle_max - 1)s
   indefinitely. Killed at WALL_MAX exactly. *)
let test_wall_backstop_kills_at_wall_max () =
  let b = L.cloud_fast in (* idle = 20, wall = 180 *)
  let s = ref (L.initial ~started_at:0.0) in
  let kill_class = ref None in
  let t = ref 0.0 in
  while not (L.is_terminal !s) && !t < 300.0 do
    t := !t +. 19.0;
    let s', _ = L.step b !s (L.Chunk (C.Answer_delta, !t)) in
    s := s';
    let s'', o = L.step b !s (L.Tick !t) in
    s := s'';
    (match o with
     | L.Outcome f -> kill_class := Some f
     | _ -> ())
  done;
  match !kill_class with
  | Some L.Wall_exceeded -> ()
  | Some other ->
      Alcotest.failf "expected Wall_exceeded, got %s"
        (L.failure_kind_label other)
  | None -> Alcotest.fail "Wall_exceeded never fired"

(* Heartbeat counts as motion (§4.4 Invariant T1 + S3). *)
let test_heartbeat_advances_clock () =
  let s = L.Streaming { started_at = 0.0; last_chunk_at = 5.0 } in
  let s', _ = L.step budget s (L.Chunk (C.Heartbeat, 15.0)) in
  Alcotest.check check_state "last_chunk_at advanced by heartbeat"
    (L.Streaming { started_at = 0.0; last_chunk_at = 15.0 }) s'

let () =
  let case name f = Alcotest.test_case name `Quick f in
  Alcotest.run "Cascade_attempt_liveness"
    [
      ( "decision_table",
        [
          case "Awaiting × chunk(any) → Streaming"
            test_awaiting_chunk_any_to_streaming;
          case "Awaiting × Tick(t≥ttft) → Failed No_first_token"
            test_awaiting_ttft_kills;
          case "Awaiting × Tick(t<ttft) → continue"
            test_awaiting_just_under_ttft_continues;
          case "Awaiting × Provider_wire_error → Failed Provider_error"
            test_awaiting_provider_error;
          case "Streaming × chunk(any) advances last_chunk_at"
            test_streaming_chunk_advances_clock;
          case "Streaming × Tick(gap≥idle) → Failed Inter_chunk_idle"
            test_streaming_inter_chunk_idle_kills;
          case "Streaming × Tick(wall≥wall_max) → Failed Wall_exceeded"
            test_streaming_wall_exceeded_kills;
          case "Streaming × Tick (both expire) → inter-chunk wins (L2)"
            test_streaming_inter_chunk_wins_over_wall;
          case "Streaming × chunk(Done) → Success"
            test_streaming_done_to_success;
          case "Awaiting × chunk(Done) → Success"
            test_awaiting_done_to_success;
          case "Streaming × Provider_wire_error → Failed Provider_error"
            test_streaming_provider_error;
          case "Failed state absorbs events" test_failed_state_is_absorbing;
          case "Success state absorbs events"
            test_success_state_is_absorbing;
        ] );
      ( "properties",
        [
          case "§8.4 thinking-only stream killed by wall, not inter-chunk"
            test_thinking_protection_hits_wall_only;
          case "§8.5 hung first byte killed at TTFT"
            test_hung_first_byte_kills_at_ttft;
          case "§8.6 mid-stream stall killed at last_chunk_at + IDLE_MAX"
            test_mid_stream_stall_kills_at_idle;
          case "§8.7 wall backstop fires at WALL_MAX even with chunks"
            test_wall_backstop_kills_at_wall_max;
          case "Heartbeat advances clock (§4.4 S3)"
            test_heartbeat_advances_clock;
        ] );
    ]
