(** Keeper_runtime_resolved — freeze keeper runtime knobs after bootstrap.

    Values resolve with the existing precedence order:
    environment > runtime.toml boot override > compiled default.

    Before [init] is called, readers see a live snapshot of the current env/boot
    override state. After [init], reads are frozen to the bootstrap snapshot so
    late env drift cannot change keeper execution behaviour.

    [stream_idle_timeout_sec] additionally substitutes a fail-safe liveness floor
    ({!stream_idle_failsafe_floor_sec}) when unset (RFC-0345, #25128),
    [first_event_timeout_sec] substitutes {!first_event_failsafe_floor_sec}
    (RFC-AC-037) and [provider_call_deadline_sec] substitutes
    {!provider_call_deadline_failsafe_floor_sec}; an explicit value still
    overrides each. *)

type source =
  | Env
  | Toml
  | Default
  | Failsafe_floor
      (** The compiled default was [None] (unset) and a fail-safe liveness
          floor was substituted. Applies to [stream_idle_timeout_sec]
          (RFC-0345), [first_event_timeout_sec] (RFC-AC-037) and
          [provider_call_deadline_sec]. *)

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  stream_idle_timeout_sec : float field;
      (** An explicit value or {!stream_idle_failsafe_floor_sec}. *)
  first_event_timeout_sec : float field;
      (** An explicit value or {!first_event_failsafe_floor_sec}. *)
  body_timeout_override_sec : float option field;
      (** The one setting with a real "not configured": AGENT_CORE reads
          [None] as no override on non-streaming body reads. *)
  provider_call_deadline_sec : float field;
      (** An explicit value or {!provider_call_deadline_failsafe_floor_sec}. *)
  context_window_tokens : int option field;
      (** Tokens one AGENT_CORE-lane request carries, fixed prompt and recent
          verbatim history together: an explicit env or runtime.toml value,
          or [None] when the operator declared none. Nothing is compiled in;
          an undeclared window refuses AGENT_CORE-lane candidates before
          dispatch. *)
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

val stream_idle_timeout_sec : unit -> float
(** Streaming-provider inter-line idle-gap timeout, in seconds: an explicit
    [MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC] (or runtime.toml
    [turn.stream_idle_timeout_sec]) honoured verbatim, or when unset the
    RFC-0345 fail-safe floor {!stream_idle_failsafe_floor_sec}, so a hung
    stream cannot freeze the keeper chat lane indefinitely (#25128). MASC
    does not synthesize a per-provider/model tuned default and does not clamp
    an operator-provided value. Invalid configured values fail during runtime
    configuration initialization. AGENT_CORE's [?stream_idle_timeout_s] stays
    optional for callers outside the keeper; the keeper always has a value
    and passes it.

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

val first_event_timeout_sec : unit -> float
(** Streaming-provider first-event (TTFT/prefill) timeout, in seconds. One
    window from the request to the provider's first token-bearing event,
    connection and response headers included (an opening frame such as
    Responses [response.created] neither ends
    it nor extends it); [stream_idle_timeout_sec] arms the inter-line gaps
    after it (RFC-AC-037). An explicit [MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC]
    (or runtime.toml [turn.first_event_timeout_sec]) honoured verbatim, or
    when unset {!first_event_failsafe_floor_sec}. AGENT_CORE's
    [?first_event_timeout_s] stays optional for callers outside the keeper;
    the keeper always has a value and passes it.

    SSOT: {!Env_config_keeper.KeeperKeepalive.first_event_timeout_sec} (raw
    parse; [None] when unset) + {!first_event_failsafe_floor_sec} (floor). *)

(** Non-streaming HTTP body-consumption deadline override.
    [None] (env unset) skips [Builder.with_body_timeout]. [Some s] is
    forwarded through [Runtime_agent_context.body_timeout_s] for AGENT_CORE sync
    completion paths. Streaming paths ignore this knob and rely on
    [stream_idle_timeout_sec] (always set: the operator's value or the floor)
    plus the attempt watchdog.

    SSOT: {!Env_config_keeper.KeeperKeepalive.body_timeout_sec_override}. *)
val body_timeout_override_sec : unit -> float option

val provider_call_deadline_failsafe_floor_sec : float
(** Fail-safe no-progress threshold for a provider call attempt, in seconds.
    Substituted for [provider_call_deadline_sec] when no explicit value is
    configured, so a default install runs the attempt watchdog and bounds a
    tool's provider sub-call instead of holding a keeper on an attempt that
    never produces a token. The value the live workspace has carried since
    2026-08-07 (#27416), validated by the 2026-08-12 measurement: 7.5 times
    the longest legitimate progress gap of a healthy turn (120 s) and a
    quarter of the wedge it caught (65 min); above the two stream floors,
    so a silent prefill is ended by the reader's typed first-token timeout
    first. A universal liveness ceiling, not a per-provider tuned default;
    an explicit env/toml value overrides it. *)

(** The keeper's no-progress threshold for a provider call attempt on the
    Agent Core HTTP lane (#27349, measured against the turn's progress
    signal since #28417). The attempt watchdog ends an attempt that made no
    progress for this long while no tool is in flight and no approval is
    pending; a tool's provider sub-call runs under it
    ({!Keeper_provider_subcall}), and so does the identity tools' MCP
    transport ({!Keeper_identity_tools}). The official-client lanes (Codex,
    Claude Code, Antigravity) do not pass through it; their turn window and
    wall-clock ceiling are declared on their bindings. An explicit
    [MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC] (or runtime.toml
    [turn.provider_call_deadline_sec]) honoured verbatim, or when unset
    {!provider_call_deadline_failsafe_floor_sec}. There is no "off": a
    keeper turn that could not be ended by this threshold would be one only
    an operator could end. It is never shorter than a stream budget the
    operator declared: that pair raises {!Env_config_core.Config_error}
    when the configuration is frozen, since the declared budget could never
    be reached. A floored budget is a ceiling, not an allowance, so an
    explicit threshold shorter than one stands.

    SSOT: {!Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override}. *)
val provider_call_deadline_sec : unit -> float

val context_window_tokens : unit -> int option
(** Tokens one AGENT_CORE-lane request carries, fixed prompt and recent
    verbatim history together (RFC keeper-context-window-in-tokens): an
    explicit [MASC_KEEPER_CONTEXT_WINDOW_TOKENS] or runtime.toml
    [turn.context_window_tokens], or [None] when undeclared. Frozen at
    bootstrap with the other turn settings. *)
