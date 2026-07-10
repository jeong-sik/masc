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
  | Derived

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  bootstrap_max_active_keepers : int field;
  reactive_max_idle_turns : int field;
  autonomous_max_idle_turns : int field;
  idle_skip_threshold : int field;
  turn_timeout_sec : float field;
  admission_wait_timeout_sec : float field;
  oas_timeout_override_sec : float option field;
  stream_idle_timeout_sec : float field;
  execution_idle_timeout_sec : float option field;
  body_timeout_override_sec : float option field;
  oas_timeout_per_1k : float field;
  oas_timeout_per_turn : float field;
}

val init : unit -> unit
val reset_for_tests : unit -> unit
val current : unit -> t

val source_to_string : source -> string
val to_yojson : t -> Yojson.Safe.t

val bootstrap_max_active_keepers : unit -> int
val reactive_max_idle_turns : unit -> int
val autonomous_max_idle_turns : unit -> int
val idle_skip_threshold : unit -> int
val turn_timeout_sec : unit -> float
val admission_wait_timeout_sec : unit -> float
val stream_idle_timeout_sec : unit -> float
val execution_idle_timeout_sec : unit -> float option
(** Resolved [turn.execution_idle_timeout_sec].

    The keeper runtime currently parses this value but does not forward it to
    OAS until active tool execution is proven to be excluded from idle
    accounting.

    Default disabled, clamped to [5, 600] when explicitly set. Unset, invalid,
    [MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC=0], or
    [turn.execution_idle_timeout_sec = 0] disables it. *)

val stream_idle_timeout_for_total_timeout : total_timeout_s:float -> float

(** Non-streaming HTTP body-consumption deadline override.
    [None] (env unset) skips [Builder.with_body_timeout]. [Some s] is
    forwarded through [Runtime_agent_context.body_timeout_s] for OAS sync
    completion paths. Streaming paths ignore this knob and rely on
    [stream_idle_timeout_sec] plus the attempt liveness observer.

    SSOT: {!Env_config_keeper.KeeperKeepalive.body_timeout_sec_override}. *)
val body_timeout_override_sec : unit -> float option

(** CLI subprocess stdout-idle timeout, read fresh per turn from
    [MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC] and clamped to [10, 600].
    Default 120 s. Honoured by [Json_stream_cli_transport_local]; other CLI
    transports require an OAS upstream change to expose
    [stdout_idle_timeout_s]. *)
val cli_subprocess_idle_sec : unit -> float
val oas_call_timeout_sec : unit -> float
(** Resolved OAS-call timeout: legacy override
    [oas_timeout_override_sec] when set, otherwise [turn_timeout_sec].
    RFC-0156: no token- or turn-budget dependence. *)
