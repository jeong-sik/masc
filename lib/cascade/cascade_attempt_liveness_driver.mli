(** Mode-aware FSM driver for the cascade attempt-liveness gate
    (RFC-0022 PR-3/4).

    Bridges the pure decision modules
    ({!Cascade_attempt_liveness.step} +
    {!Cascade_attempt_liveness_runtime.decide}) to a side-effecting
    callback shape suitable for OAS streaming
    ({!Agent_sdk.Agent.run_stream}'s [~on_event]) and a wall-clock
    fiber.

    {1 Wiring contract}

    A caller that wants attempt liveness wraps a single OAS attempt as:

    {[
      let h = Driver.create ~budget ~mode ~provider_label ~now in
      let on_event evt = Driver.observe_sse h evt (now ()) in
      let abort = ref false in
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          Eio.Time.sleep clock (Driver.tick_period h);
          (match Driver.on_tick h (now ()) with
           | `Continue -> loop ()
           | `Abort -> abort := true)  (* enforce-mode kill *)
        in loop ());
      Agent_sdk.Agent.run_stream ~sw ~on_event ... agent goal
    ]}

    All side effects (Prometheus inc, [Log.warn], abort signal) happen
    inside the driver so the caller does not need to know about
    {!Cascade_attempt_liveness_runtime.side_effect}.

    {1 Production status}

    No keeper turn currently invokes streaming with [~on_event], so
    this module is dormant in the production hot path.  It is wired
    into the public [masc_mcp] library and unit-tested end-to-end so
    a follow-up PR can opt the keeper into streaming + liveness in
    one step.

    @since RFC-0022 PR-3 *)

(** Opaque per-attempt driver handle. *)
type t

(** {1 Constructors} *)

val create :
  budget:Cascade_attempt_liveness.budget ->
  mode:Env_config_keeper.CascadeAttemptLiveness.mode ->
  provider_label:string ->
  started_at:float ->
  t
(** Build a fresh driver for one attempt.  [provider_label] is used as
    a Prometheus [provider] label value on any kill counter increments. *)

(** {1 Event sinks} *)

(** Verdict surfaced to the caller after a single observation. *)
type verdict =
  | Continue
      (** The caller may proceed with the attempt. *)
  | Abort
      (** Enforce-mode kill — the caller must abort the streaming
          fiber (e.g. cancel the [Eio.Switch]). *)

val observe_sse : t -> Agent_sdk.Types.sse_event -> float -> verdict
(** Feed a single SSE event observed at wall-clock time [received_at].
    Returns the FSM verdict so the caller can decide whether to
    continue.  Side effects (Prometheus inc, structured log line) are
    emitted internally on a kill.  Events that do not represent
    forward motion (e.g. [SSEError]) are ignored. *)

val on_tick : t -> float -> verdict
(** Feed a clock tick at wall-clock time [now].  The clock fiber
    typically calls this every {!tick_period} seconds. *)

val tick_period : t -> float
(** Recommended tick period — finer than [budget.ttft_max] and
    [budget.inter_chunk_max] so any boundary is detected within the
    next tick. *)

(** {1 Introspection (testing)} *)

val current_state : t -> Cascade_attempt_liveness.state
(** Current FSM state, exposed for white-box tests. *)
