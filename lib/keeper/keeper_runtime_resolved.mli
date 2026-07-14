(** Keeper_runtime_resolved — freeze keeper runtime knobs after bootstrap.

    Values resolve with the existing precedence order:
    environment > runtime.toml boot override > compiled default.

    Before [init] is called, readers see a live snapshot of the current env/boot
    override state. After [init], reads are frozen to the bootstrap snapshot so
    late env drift cannot change keeper execution behaviour. *)

type source =
  | Env
  | Toml
  | Default

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

val stream_idle_timeout_sec : unit -> float option
(** Explicit streaming-provider idle-gap timeout. [None] means disabled.
    MASC does not synthesize a provider/model default and does not clamp an
    operator-provided value. Invalid configured values fail during runtime
    configuration initialization.

    SSOT: {!Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec}. *)

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
