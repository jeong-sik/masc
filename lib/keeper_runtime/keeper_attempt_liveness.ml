(** Runtime attempt-level streaming liveness gate (RFC-0022 PR-1/4).

    Implementation of the decision table in
    [docs/rfc/RFC-0022-runtime-attempt-liveness.md] §4.5.

    Pure FSM. No IO, no clock read, no fiber. Caller (PR-2) supplies
    monotonic timestamps via {!event} and consumes {!output} for
    Otel_metric_store / log emission. *)

type budget = {
  ttft_max : float;
  attempt_wall_max : float;
}

(* Conservative first-attempt budget used before the runtime has observed a
   successful sample for the concrete provider/model candidate. Later attempts
   are tuned from successful TTFT/wall samples in
   [Keeper_attempt_liveness_config]. *)
let bootstrap : budget =
  { ttft_max = 600.0; attempt_wall_max = 1800.0 }

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
  | Wall_exceeded
  | Provider_error of string

let failure_kind_label = function
  | No_first_token -> "no_first_token"
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

(** Metric recorder — caller (e.g. runtime_attempt_liveness_observer)
    supplies callbacks for TTFT seconds and liveness outcome.
    Pure FSM stays IO-free; side effects live in the recorder. *)
type recorder = {
  record_ttft : float -> unit;
  record_liveness_outcome : failure option -> unit;
}

let null_recorder = {
  record_ttft = (fun _ -> ());
  record_liveness_outcome = (fun _ -> ());
}

(* Decision table — RFC-0022 §4.5.

   Invariants enforced here:
   - S1: every chunk except Done advances last_chunk_at.
   - S2: Done in Streaming → Success terminal; no further state moves.
   - T1: Heartbeat / Thinking_delta both count as motion.
   - L2: TTFT is the specific stream-liveness kill class.
         A cumulative wall can only apply before the stream has produced a
         first chunk. *)

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
      let ttft_seconds = received_at -. started_at in
      recorder.record_ttft ttft_seconds;
      ( Streaming { started_at; last_chunk_at = received_at }
      , Continue )

  (* Awaiting × Tick: check TTFT first, wall second.
     [now - started_at >= ttft_max] is the more specific no-first-token
     failure. [attempt_wall_max] applies only while Awaiting so a shorter
     pre-stream backstop cannot wait forever for a first chunk. *)
  | Awaiting { started_at }, Tick now ->
      let wall = now -. started_at in
      if wall >= b.ttft_max then begin
        recorder.record_liveness_outcome (Some No_first_token);
        (Failed No_first_token, Outcome No_first_token)
      end else if wall >= b.attempt_wall_max then begin
        recorder.record_liveness_outcome (Some Wall_exceeded);
        (Failed Wall_exceeded, Outcome Wall_exceeded)
      end else
        (s, Continue)

  (* Awaiting × Provider_wire_error: provider failed before any chunk;
     classify as wire error, not liveness — let runtime FSM decide. *)
  | Awaiting _, Provider_wire_error msg ->
      recorder.record_liveness_outcome (Some (Provider_error msg));
      ( Failed (Provider_error msg)
      , Outcome (Provider_error msg) )

  (* Streaming × chunk(Done): success. *)
  | Streaming _, Chunk (Stream_chunk.Done, _) ->
      (Success, Completed)

  (* Streaming × chunk(any non-Done): advance last_chunk_at. *)
  | Streaming { started_at; last_chunk_at = prev_last }, Chunk (_, received_at) ->
      ( Streaming { started_at; last_chunk_at = received_at }
      , Continue )

  (* Streaming × Tick: once the provider has emitted chunks, liveness is
     progress-based. A stream that keeps producing chunks must not be killed
     only because cumulative wall-clock elapsed. *)
  | Streaming _, Tick _ ->
      (s, Continue)

  | Streaming _, Provider_wire_error msg ->
      recorder.record_liveness_outcome (Some (Provider_error msg));
      ( Failed (Provider_error msg)
      , Outcome (Provider_error msg) )
