(** Cascade attempt-liveness observer (RFC-0022 PR-2/4 §4-5).

    Glue layer between {!Cascade_attempt_liveness} (pure FSM) and the
    streaming attempt loop in [oas_worker_named.ml]. Owns:

    - The mutable FSM state ref bound to one cascade attempt.
    - Translation from [Agent_sdk.Types.sse_event] to
      {!Cascade_attempt_liveness.Stream_chunk.kind}.
    - Tick fiber forked under the caller's [Eio.Switch.t] that polls
      the FSM at [min(ttft_max, inter_chunk_max) / 4] cadence.
    - Prometheus counter emission per outcome.

    {1 No-kill in Observe mode}

    Structural guarantee (RFC §4 contract):

    - [Off] mode: caller short-circuits before constructing the
      observer. [{!create}] in [Off] returns a no-op handle.
    - [Observe] mode: counters fire but neither [Switch.fail] nor any
      exception leaves this module. The wrapped [on_event] callback is
      bit-identical to the baseline (delegates to the original) plus
      side-effecting telemetry only.
    - [Enforce] mode: on the first [Outcome] the observer calls
      [Eio.Switch.fail sw {!Liveness_kill}] so the surrounding
      [Cascade_runner.run] tears down via Eio cancellation.

    {1 Tick fiber lifetime}

    The tick fiber is forked under the same [~sw] that owns
    [Cascade_runner.run]. When the OAS run switch dies (success,
    error, parent cancellation) the tick fiber dies with it — no
    explicit teardown is required.

    @stability Evolving
    @since 0.190.0 *)

exception Liveness_kill of Cascade_attempt_liveness.failure
(** Raised via [Eio.Switch.fail] in {!Enforce} mode when the FSM
    emits an {!Cascade_attempt_liveness.Outcome}. The argument is the
    classified failure carried into the cascade FSM by the caller. *)

type t
(** Opaque per-attempt observer handle. *)

val create :
  mode:Cascade_attempt_liveness_config.mode ->
  budget:Cascade_attempt_liveness.budget ->
  cascade_label:string ->
  provider_label:string ->
  started_at:float ->
  t
(** Build an observer for one cascade attempt.

    [started_at] is the monotonic wall-clock the caller already
    captured for [attempt_started_at] (oas_worker_named.ml:508).

    The observer does not own the switch — see [start_tick_fiber]. *)

val wrap_on_event :
  t ->
  (Agent_sdk.Types.sse_event -> unit) option ->
  (Agent_sdk.Types.sse_event -> unit) option
(** [wrap_on_event obs original] returns a callback that forwards every
    event to [original] (preserving baseline semantics) and feeds a
    derived {!Cascade_attempt_liveness.Chunk} into the FSM.

    Mode contract:
    - [Off]: returns [original] unchanged (no allocation).
    - [Observe]: returns [Some f] where [f] always calls [original]
      then the FSM step + telemetry.
    - [Enforce]: same as [Observe] plus may [Eio.Switch.fail] on
      [Outcome]. *)

val register_attempt_switch :
  t ->
  sw:Eio.Switch.t ->
  unit
(** Register the provider-attempt switch used by enforce mode.

    This is separate from {!start_tick_fiber} so callers without an
    available Eio clock can still scope [Liveness_kill] cancellation to the
    current provider attempt. *)

val start_tick_fiber :
  t ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  unit
(** Fork a sibling fiber under [~sw] that calls [Cascade_attempt_liveness.step]
    with [Tick now] every [min(ttft_max, inter_chunk_max) / 4] seconds
    until the FSM reaches a terminal state or [~sw] dies.

    No-op when the observer mode is {!Off} or when [Off] short-circuit
    elided observer construction at the call site. The fiber holds a
    reference to [t] only — no other shared state — and dies with the
    parent switch (Invariant §8 cancellation cleanup). *)

val finalize : t -> unit
(** Emit the [observed_total] counter once with the final outcome
    label inferred from the FSM state at finalization time:

    - [Success]    -> [outcome=success]
    - [Failed _]   -> [outcome=kill] for liveness kills, or
                       [outcome=wire_error] for [Provider_error].
    - [Awaiting _]
    | [Streaming _] -> [outcome=wire_error] (caller terminated the
      attempt before the FSM saw a Done — typically a wire
      cancellation or upstream exception).

    Idempotent: calling twice emits the counter once. *)

val current_state_for_test : t -> Cascade_attempt_liveness.state
(** Test-only accessor. Production callers must not depend on this. *)

val mode : t -> Cascade_attempt_liveness_config.mode
(** Reflect the mode that was captured at observer construction. *)
