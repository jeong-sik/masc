(** Keeper_runtime_resolved — freeze keeper runtime knobs after bootstrap.

    Values resolve with the existing precedence order:
    environment > runtime.toml boot override > compiled default.

    Before [init] is called, readers see a live snapshot of the current env/boot
    override state. After [init], reads are frozen to the bootstrap snapshot so
    late env drift cannot change keeper execution behaviour.

    [stream_idle_timeout_sec] additionally substitutes a fail-safe liveness floor
    ({!stream_idle_failsafe_floor_sec}) when unset (RFC-0345, #25128), and
    [first_event_timeout_sec] substitutes {!first_event_failsafe_floor_sec}
    (RFC-AC-037); an explicit value still overrides either. *)

type source =
  | Env
  | Toml
  | Default
  | Failsafe_floor
      (** The compiled default was [None] (unset) and a fail-safe liveness
          floor was substituted. Applies to [stream_idle_timeout_sec]
          (RFC-0345) and [first_event_timeout_sec] (RFC-AC-037). *)

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  stream_idle_timeout_sec : float option field;
  first_event_timeout_sec : float option field;
  body_timeout_override_sec : float option field;
  provider_call_deadline_sec : float option field;
}

val init : unit -> unit
val reset_for_tests : unit -> unit
val current : unit -> t

val source_to_string : source -> string
val to_yojson : t -> Yojson.Safe.t

val stream_idle_failsafe_floor_sec : float
(** RFC-0345 fail-safe liveness floor for the streaming inter-line idle timeout,
    in seconds (600.0 = 10 min). Substituted for [stream_idle_timeout_sec] when
    no explicit value is configured, so a hung provider stream cannot freeze the
    keeper chat lane indefinitely (#25128). A universal liveness ceiling, not a
    per-provider tuned default; an explicit env/toml value overrides it. *)

val stream_idle_timeout_sec : unit -> float option
(** Streaming-provider inter-line idle-gap timeout, in seconds. Always [Some] at
    runtime: an explicit [MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC] (or runtime.toml
    [turn.stream_idle_timeout_sec]) is honoured verbatim; when unset, the
    RFC-0345 fail-safe floor {!stream_idle_failsafe_floor_sec} is substituted so
    a hung stream cannot freeze the keeper chat lane indefinitely (#25128). MASC
    does not synthesize a per-provider/model tuned default and does not clamp an
    operator-provided value. Invalid configured values fail during runtime
    configuration initialization. The [float option] return type is retained for
    the existing [?stream_idle_timeout_s] wiring; the resolver no longer yields
    [None].

    SSOT: {!Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec} (raw
    parse; [None] when unset) + {!stream_idle_failsafe_floor_sec} (floor). *)

val first_event_failsafe_floor_sec : float
(** Fail-safe bound for the silent first-event (TTFT/prefill) wait, in seconds
    (600.0 = 10 min). Substituted for [first_event_timeout_sec] when no
    explicit value is configured, so the first-event wait is never governed by
    the much shorter inter-line idle knob through AGENT_CORE's fallback chain
    (RFC-AC-037; measured silent prefill: 152s mimo 1M-context, ~200-525s
    local MLX 20.7K-token keeper prompts). A universal liveness ceiling, not a
    per-provider tuned default; an explicit env/toml value overrides it. *)

val first_event_timeout_sec : unit -> float option
(** Streaming-provider first-event (TTFT/prefill) timeout, in seconds. Bounds
    only the wait for the FIRST provider event; [stream_idle_timeout_sec] arms
    the inter-line gaps after it (RFC-AC-037). Always [Some] at runtime: an
    explicit [MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC] (or runtime.toml
    [turn.first_event_timeout_sec]) is honoured verbatim; when unset,
    {!first_event_failsafe_floor_sec} is substituted. The [float option]
    return type mirrors the transport wiring; the resolver never yields
    [None].

    SSOT: {!Env_config_keeper.KeeperKeepalive.first_event_timeout_sec} (raw
    parse; [None] when unset) + {!first_event_failsafe_floor_sec} (floor). *)

(** Non-streaming HTTP body-consumption deadline override.
    [None] (env unset) skips [Builder.with_body_timeout]. [Some s] is
    forwarded through [Runtime_agent_context.body_timeout_s] for AGENT_CORE sync
    completion paths. Streaming paths ignore this knob and rely on an
    explicitly configured [stream_idle_timeout_sec] plus the attempt liveness
    observer.

    SSOT: {!Env_config_keeper.KeeperKeepalive.body_timeout_sec_override}. *)
val body_timeout_override_sec : unit -> float option

(** Total wall-clock deadline for one provider call attempt (#27349).
    [None] (env unset) means no MASC-side enforcement -- the provider
    attempt caller skips the [Eio.Time.with_timeout_exn] wrap and runs
    unbounded, same as before this knob existed. Deliberately no failsafe
    floor: unlike [stream_idle_timeout_sec], a reasonable total-call
    ceiling depends on provider and workload, so MASC does not guess one.

    SSOT: {!Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override}. *)
val provider_call_deadline_sec : unit -> float option
