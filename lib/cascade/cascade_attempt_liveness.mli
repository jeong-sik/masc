(** Cascade attempt-level streaming liveness gate (RFC-0022 PR-1/4).

    Pure FSM that fails the *current cascade attempt* — not the turn —
    when a provider stops emitting evidence of forward motion. Three
    independent kill classes:

    - {!No_first_token}     — provider produces no chunk within [ttft_max]
    - {!Inter_chunk_idle}   — gap between consecutive chunks exceeds [inter_chunk_max]
    - {!Wall_exceeded}      — total attempt wall-clock exceeds [attempt_wall_max]

    See [docs/rfc/RFC-0022-cascade-attempt-liveness.md] §4 for the design.

    {1 Layer separation}

    This is the in-attempt layer (§1 of RFC-0022). It must not collide
    with:

    - RFC-0009 {b pre-attempt} provider trust (cascade order)
    - RFC-0012 {b cross-attempt} turn-level mid-progress watchdog

    Every chunk that advances this module's clock must also advance
    RFC-0012's [last_progress_at] (Invariant L1). The wiring is a
    caller responsibility — see [keeper_hooks_oas.ml] in PR-3.

    {1 Scope of this PR}

    This PR-1 ships the pure FSM module + property tests only.
    Production cascade behaviour is unchanged: no caller in
    [cascade_runtime.ml] consumes [step] yet. Wiring lands in PR-2 of
    the RFC-0022 stack, behind [MASC_CASCADE_ATTEMPT_LIVENESS=observe]
    by default (§9 Phase A).

    @stability Evolving
    @since 0.190.0 *)

(** {1 Liveness budget} *)

type budget = {
  ttft_max : float;
  (** Time to first chunk. Awaiting-state deadline. *)

  inter_chunk_max : float;
  (** Maximum gap between consecutive chunks once streaming starts. *)

  attempt_wall_max : float;
  (** Hard backstop on total attempt wall-clock duration. *)
}

val cloud_fast : budget
(** [30s / 20s / 180s] — [codex_cli], [claude], [gemini] short answers. *)

val cloud_thinking : budget
(** [60s / 30s / 300s] — adaptive-reasoning models with thinking deltas. *)

val local_27b : budget
(** [120s / 60s / 900s] — [ollama_only], [llama-server] mid-size local. *)

val local_70b_plus : budget
(** [240s / 90s / 1800s] — [70B+] local backstop. *)

(** {1 Stream chunk taxonomy}

    Defines what counts as a chunk for the purpose of advancing the
    liveness clock (Invariant S1 of RFC-0022 §4.4). *)

module Stream_chunk : sig
  type kind =
    | Thinking_delta
        (** Adaptive-reasoning model thinking token delta.
            Counts as motion (Invariant T1). *)

    | Answer_delta
        (** Answer token delta. *)

    | Tool_call_start of { tool_name : string }
        (** Provider declared a tool call. *)

    | Tool_call_arg_delta
        (** Provider streaming tool-call arguments. *)

    | Tool_call_complete
        (** Provider finished a tool call. *)

    | Substrate_event of { kind : string }
        (** Provider-specific protocol event (e.g. [oas:event]). *)

    | Heartbeat
        (** Protocol-level keepalive. Permitted only as a liveness
            signal during long thinking / tool-call windows; clients
            MUST NOT emit Heartbeat without underlying real activity
            (§4.4 Invariant S3). *)

    | Done
        (** Terminal — attempt success. After Done no further chunks
            are accepted (§4.4 Invariant S2). *)
end

(** {1 Failure class}

    Reported back to the cascade FSM so it can attribute the kill to
    liveness (not a wire error) and advance to the next provider. *)

type failure =
  | No_first_token
  | Inter_chunk_idle
  | Wall_exceeded
  | Provider_error of string

val failure_kind_label : failure -> string
(** Stable label for telemetry / Prometheus counter. One of
    [no_first_token | inter_chunk_idle | wall_exceeded | provider_error]. *)

(** {1 FSM state} *)

type state =
  | Awaiting of { started_at : float }
      (** No chunks received yet. Subject to [ttft_max]. *)

  | Streaming of { started_at : float; last_chunk_at : float }
      (** At least one chunk received. Subject to [inter_chunk_max]
          and [attempt_wall_max]. *)

  | Failed of failure
      (** Terminal failure. *)

  | Success
      (** Terminal success ({!Stream_chunk.Done} observed). *)

val initial : started_at:float -> state
(** Construct an initial [Awaiting] state. *)

val is_terminal : state -> bool
(** [true] iff [Failed _] or [Success]. *)

(** {1 Event}

    Inputs to {!step}. The decision table in RFC-0022 §4.5 enumerates
    every (state, event) pair.

    {2 Timestamp contract (caller responsibility)}

    All [float] timestamps in [Chunk] / [Tick] payloads ([received_at],
    [now]) MUST satisfy:

    - {b finite}: not [Float.nan], [Float.infinity] or [neg_infinity]
    - {b non-negative}: a monotonic seconds reading from the same
      clock source used to construct {!initial}'s [started_at]
    - {b monotonically non-decreasing} across consecutive events fed
      to the same FSM instance

    Validation lives in the wiring layer (PR-2 [cascade_runtime.ml]
    + PR-3 [keeper_hooks_oas.ml]) — this module is a pure FSM and
    trusts its inputs. Feeding non-finite or out-of-order timestamps
    produces undefined liveness behaviour. *)

type event =
  | Chunk of Stream_chunk.kind * float
      (** Provider emitted a chunk. The [float] is the monotonic
          [received_at]; see Timestamp contract above. *)

  | Tick of float
      (** Clock tick at monotonic time. Triggers TTFT, inter-chunk and
          wall checks; see Timestamp contract above. *)

  | Provider_wire_error of string
      (** Provider returned an error (HTTP, network, parse). The string
          is for diagnostic only — caller decides retryability. *)

(** {1 Output}

    Side-effect signal returned alongside the next state. Callers in
    PR-2 emit Prometheus counters and structured logs based on
    [Outcome]. *)

type output =
  | Continue
      (** No transition observable to caller. *)

  | Outcome of failure
      (** Attempt failed; cascade FSM should advance to next provider. *)

  | Completed
      (** Attempt succeeded. *)

(** {1 Decision function}

    {b Pure}: no IO, no clock read, no allocation outside what OCaml
    pattern-match constructs. Tests exercise the full decision table
    by feeding hand-crafted [(state, event)] pairs.

    {2 Event ordering contract}

    Deadlines fire on [Tick] only — by design (RFC-0022 §4.5 + §4.4
    Invariant S1). To bound the late-chunk window the {b caller} MUST:

    {ol
    {- emit [Tick] at a cadence ≤ [min budget.ttft_max
       budget.inter_chunk_max] for the active state, and}
    {- when both an overdue [Tick] and a late [Chunk] are observable
       at the wiring layer, deliver the overdue [Tick] {b first} so
       the FSM can transition to [Failed] before the chunk reopens
       the streaming clock.}}

    Concretely the PR-2 wiring (`cascade_runtime.ml`) drives this via
    a single fiber that drains the chunk queue and emits a [Tick]
    after each empty poll; PR-3 (`keeper_hooks_oas.ml`) carries the
    same ordering guarantee into the RFC-0012 lockstep clock. Callers
    that fan chunks and ticks across separate fibers must enforce this
    ordering themselves (e.g. via a single [Lwt_stream] / [Eio.Stream]
    pulled by one consumer). *)

val step : budget -> state -> event -> state * output
