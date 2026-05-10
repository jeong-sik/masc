(** Cascade attempt-level streaming liveness gate (RFC-0022 PR-1/4).

    Implementation of the decision table in
    [docs/rfc/RFC-0022-cascade-attempt-liveness.md] §4.5.

    Pure FSM. No IO, no clock read, no fiber. Caller (PR-2) supplies
    monotonic timestamps via {!event} and consumes {!output} for
    Prometheus / log emission. *)

type budget = {
  ttft_max : float;
  inter_chunk_max : float;
  attempt_wall_max : float;
}

(* §4.1 Recommended starting points. Final values must be empirically
   calibrated against [scripts/diag-keeper-cycle.sh] output after
   PR-2 wiring is enabled in [observe] mode. *)

let cloud_fast : budget =
  { ttft_max = 30.0; inter_chunk_max = 20.0; attempt_wall_max = 180.0 }

let cloud_thinking : budget =
  { ttft_max = 60.0; inter_chunk_max = 30.0; attempt_wall_max = 300.0 }

(* Calibrated 2026-05-09 against cold-start TTFT for qwen3.6:27b-coding-nvfp4
   on Apple Silicon: 452s cold vs 31s warm (same prompt). Previous 180s
   rejected legitimate cold-start turns before first token. *)
let local_27b : budget =
  { ttft_max = 600.0; inter_chunk_max = 90.0; attempt_wall_max = 1200.0 }

let local_70b_plus : budget =
  { ttft_max = 300.0; inter_chunk_max = 120.0; attempt_wall_max = 1800.0 }

module Stream_chunk = struct
  type kind =
    | Thinking_delta
    | Answer_delta
    | Tool_call_start of { tool_name : string }
    | Tool_call_arg_delta
    | Tool_call_complete
    | Substrate_event of { kind : string }
    | Heartbeat
    | Done
end

type failure =
  | No_first_token
  | Inter_chunk_idle
  | Wall_exceeded
  | Provider_error of string

let failure_kind_label = function
  | No_first_token -> "no_first_token"
  | Inter_chunk_idle -> "inter_chunk_idle"
  | Wall_exceeded -> "wall_exceeded"
  | Provider_error _ -> "provider_error"

type state =
  | Awaiting of { started_at : float }
  | Streaming of { started_at : float; last_chunk_at : float }
  | Failed of failure
  | Success

let initial ~started_at = Awaiting { started_at }

let is_terminal = function
  | Failed _ | Success -> true
  | Awaiting _ | Streaming _ -> false

type event =
  | Chunk of Stream_chunk.kind * float
  | Tick of float
  | Provider_wire_error of string

type output =
  | Continue
  | Outcome of failure
  | Completed

(** Metric recorder — caller (e.g. cascade_attempt_liveness_observer)
    supplies callbacks for TTFT, TBT, and liveness outcome.
    Pure FSM stays IO-free; side effects live in the recorder. *)
type recorder = {
  record_ttft : float -> unit;
  record_inter_chunk : float -> unit;
  record_liveness_outcome : failure option -> unit;
}

let null_recorder = {
  record_ttft = (fun _ -> ());
  record_inter_chunk = (fun _ -> ());
  record_liveness_outcome = (fun _ -> ());
}

(* Decision table — RFC-0022 §4.5.

   Invariants enforced here:
   - S1: every chunk except Done advances last_chunk_at.
   - S2: Done in Streaming → Success terminal; no further state moves.
   - T1: Heartbeat / Thinking_delta both count as motion.
   - L2: TTFT and inter-chunk checks fire before wall when both expire
         on the same tick (caller of cascade_fsm gets the most specific
         kill class; matches §1 invariant L2 "no double kill"). *)

let step ?(recorder = null_recorder) (b : budget) (s : state) (e : event)
  : state * output =
  match s, e with
  (* Terminal states absorb every event without moving. The FSM does
     not re-enter Awaiting once it has left. *)
  | (Failed _ as fs), _ -> (fs, Continue)
  | (Success as ss), _ -> (ss, Continue)

  (* Awaiting × chunk(Done): provider returned Done before producing
     any token. Treat as Success (caller's accept predicate decides
     whether the empty body is acceptable; this FSM only tracks
     liveness). *)
  | Awaiting _, Chunk (Stream_chunk.Done, _) ->
      (Success, Completed)

  (* Awaiting × chunk(any non-Done): transition to Streaming. *)
  | Awaiting { started_at }, Chunk (_, received_at) ->
      let ttft_ms = (received_at -. started_at) *. 1000.0 in
      recorder.record_ttft ttft_ms;
      ( Streaming { started_at; last_chunk_at = received_at }
      , Continue )

  (* Awaiting × Tick: TTFT check.
     [now - started_at >= ttft_max] kills the attempt. *)
  | Awaiting { started_at }, Tick now
    when now -. started_at >= b.ttft_max ->
      recorder.record_liveness_outcome (Some No_first_token);
      (Failed No_first_token, Outcome No_first_token)

  | Awaiting _, Tick _ -> (s, Continue)

  (* Awaiting × Provider_wire_error: provider failed before any chunk;
     classify as wire error, not liveness — let cascade FSM decide. *)
  | Awaiting _, Provider_wire_error msg ->
      recorder.record_liveness_outcome (Some (Provider_error msg));
      ( Failed (Provider_error msg)
      , Outcome (Provider_error msg) )

  (* Streaming × chunk(Done): success. *)
  | Streaming _, Chunk (Stream_chunk.Done, _) ->
      (Success, Completed)

  (* Streaming × chunk(any non-Done): advance last_chunk_at. *)
  | Streaming { started_at; last_chunk_at = prev_last }, Chunk (_, received_at) ->
      let tbt_ms = (received_at -. prev_last) *. 1000.0 in
      recorder.record_inter_chunk tbt_ms;
      ( Streaming { started_at; last_chunk_at = received_at }
      , Continue )

  (* Streaming × Tick: check inter-chunk first, wall second.
     Per L2, the more specific kill class wins when both expire on
     the same tick — inter-chunk is more specific (gap-based) than
     wall (cumulative). *)
  | Streaming { started_at; last_chunk_at }, Tick now ->
      let gap = now -. last_chunk_at in
      let wall = now -. started_at in
      if gap >= b.inter_chunk_max then begin
        recorder.record_liveness_outcome (Some Inter_chunk_idle);
        (Failed Inter_chunk_idle, Outcome Inter_chunk_idle)
      end else if wall >= b.attempt_wall_max then begin
        recorder.record_liveness_outcome (Some Wall_exceeded);
        (Failed Wall_exceeded, Outcome Wall_exceeded)
      end else
        (s, Continue)

  | Streaming _, Provider_wire_error msg ->
      recorder.record_liveness_outcome (Some (Provider_error msg));
      ( Failed (Provider_error msg)
      , Outcome (Provider_error msg) )
