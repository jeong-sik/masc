(** Keeper_runtime_resolved — freeze keeper runtime knobs after bootstrap.

    Values resolve with the existing precedence order:
    environment > runtime.toml boot override > compiled default.

    Before [init] is called, readers see a live snapshot of the current env/boot
    override state. After [init], reads are frozen to the bootstrap snapshot so
    late env drift cannot change keeper execution behaviour.

    [stream_idle_timeout_sec] additionally substitutes a fail-safe liveness floor
    ({!stream_idle_failsafe_floor_sec}) when unset (RFC-0345, #25128); an explicit
    value still overrides. *)

type source =
  | Env
  | Toml
  | Default
  | Failsafe_floor
      (** The compiled default was [None] (unset) and the RFC-0345 fail-safe
          liveness floor was substituted. Applies to [stream_idle_timeout_sec]
          only. *)

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  stream_idle_timeout_sec : float option field;
  body_timeout_override_sec : float option field;
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

(** Non-streaming HTTP body-consumption deadline override.
    [None] (env unset) skips [Builder.with_body_timeout]. [Some s] is
    forwarded through [Runtime_agent_context.body_timeout_s] for OAS sync
    completion paths. Streaming paths ignore this knob and rely on an
    explicitly configured [stream_idle_timeout_sec] plus the attempt liveness
    observer.

    SSOT: {!Env_config_keeper.KeeperKeepalive.body_timeout_sec_override}. *)
val body_timeout_override_sec : unit -> float option

(** CLI subprocess stdout-idle timeout, read fresh per turn from
    [MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC] and clamped to [10, 600].
    Default 120 s. Honoured by [Json_stream_cli_transport_local]; other CLI
    transports require an OAS upstream change to expose
    [stdout_idle_timeout_s]. *)
val cli_subprocess_idle_sec : unit -> float
