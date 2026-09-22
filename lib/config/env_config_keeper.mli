(** Env_config_keeper — keeper runtime parameters from environment.

    All [MASC_KEEPER_*] env vars in this module can also be set
    declaratively in [<resolved config root>/runtime.toml].
    Precedence: process env > TOML > hardcoded default.

    Surface flows through [include Env_config_keeper] in
    {!Env_config}, so callers reach values either as
    [Env_config.<Module>.<field>] or as [Env_config.<top_level>] for
    the few unscoped lets at this boundary. *)

(** {1 Keeper bootstrap} *)

module KeeperBootstrap : sig
  val enabled : unit -> bool
  val lazy_startup_poll_interval_sec : float
  val keeper_listener_retry_interval_sec : float
  val post_startup_settle_sec : float
end
(** {1 Keeper metrics rotation} *)

module KeeperSpawn : sig
  val spawn_output_buffer_bytes : int
  (** Bytes of each spawned process stream {!Spawn_registry} keeps. Bounded
      because a process can outrun any reader; [read] reports every byte the
      bound cost, so this is a limit rather than a silent truncation. *)
end

module KeeperMetrics : sig
  val max_file_bytes : int
  val max_rotated_files : int
end

(** {1 Keeper wire capture} *)

module KeeperWireCapture : sig
  val enabled : unit -> bool
  val retention_days : unit -> int
  val max_bytes : unit -> int
end

(** {1 Keeper supervisor} *)

module KeeperSupervisor : sig
  val sweep_interval_sec : float
end

(** {1 Keeper poll intervals} *)

module KeeperPollIntervals : sig
  val crash_persistence_drain_sec : float
end

(** {1 Autonomous turns} *)

module KeeperAutonomous : sig
  val max_wake_prompt_bytes : int
  (** Byte bound on a wake prompt. The value is appended to the durable
      checkpoint every autonomous turn, so its cost recurs for the life of the
      conversation rather than being paid once. *)

  val validate_wake_prompt : string -> (string, string) result
  (** Trims, then rejects blank and over-bound values with an operator-facing
      reason. Applied where [MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT] is read. *)

  val default_wake_prompt : string
  (** Wording used when the fleet does not configure one. Single definition;
      {!Keeper_unified_prompt.autonomous_wake_marker} aliases it. *)


  val wake_prompt : unit -> string
  (** Fleet value else {!default_wake_prompt} -- what a keeper with no override
      of its own is woken with, and what the operator settings projection
      reports. *)
end

(** {1 Keeper runtime} *)

module KeeperRuntime : sig
  val debug : bool
  val snapshot_sec : int
end

(** {1 Keeper Memory OS} *)

module KeeperMemoryOs : sig
  type librarian_config_state =
    | Enabled
    | Disabled
    | Invalid

  (** Env-var names (SSOT). The config-introspection registry and tests must
      reference these constants rather than re-spelling the literals, so a
      knob rename breaks compilation instead of silently drifting. *)

  val librarian_env_key : string


  val librarian_config_state : unit -> librarian_config_state
  (** Typed projection of the effective librarian toggle. Blank or absent
      input uses {!librarian_enabled_default}; malformed non-blank input is
      [Invalid] rather than being collapsed into [Disabled]. *)

  val recall_enabled : unit -> bool
end

(** {1 Keeper vision tool} *)

module KeeperVision : sig
  (** Raw image-byte budget for [keeper_analyze_image], clamped to [1, 10 MiB]. *)
  val max_image_bytes : unit -> int

  (** Output-token budget for [keeper_analyze_image], shared by the reasoning phase and
      the answer on the /v1 vision fleet, clamped to [4096, 131072]. Default
      65536. *)
  val max_output_tokens : unit -> int

  (** Base inter-candidate backoff, clamped to [0, 5] seconds. *)
  val candidate_backoff_base_sec : unit -> float

  (** Max inter-candidate backoff, clamped to [base, 30] seconds. *)
  val candidate_backoff_max_sec : unit -> float

  (** Maximum image dimension (longest edge) before downscaling, clamped to [256, 8192].
      Default: 1568. *)
  val max_dimension : unit -> int
end

(** {1 Keeper lane gate} *)

module KeeperLaneGate : sig
  (** Total admission budget shared by one submit's submission-lane and
      persistence-lane acquisitions, clamped to (0, 600] seconds. Default
      60.0. On expiry submit fails with [Submit_lane_unavailable] instead of
      hanging behind a stuck durable write (#25398). *)
  val admission_wait_budget_sec : unit -> float
end

(** {1 Keeper turn admission bounds} *)

module KeeperAdmissionBounds : sig
  (** Maximum durable queue selections admitted into one turn, clamped to
      [1, 256]. Default 32. Selections past this bound stay pending for a later
      turn (#29365). *)
  val max_events : unit -> int
end

(** {1 Keeper generated media} *)

module KeeperGeneratedMedia : sig
  (** Raw generated-media byte budget for durable store and serve, clamped to
      [1, 50 MiB]. *)
  val max_bytes : unit -> int

  (** Generated-media directory byte cap after opportunistic cleanup, clamped to
      [1, 5 GiB]. *)
  val dir_max_bytes : unit -> int

  (** Generated-media file retention age for opportunistic cleanup, clamped to
      [1 second, 30 days]. *)
  val retention_seconds : unit -> float
end

(** {1 Work-as-Heartbeat (Phase 1)} *)

module WorkAsHeartbeat : sig
  val enabled : bool
end

(** {1 Keeper keepalive loop} *)

module KeeperKeepalive : sig
  val interval_sec : int
  val sleep_chunk_sec : float

  val rate_limit_backoff_floor_sec : float
  (** How long a path rests after a provider throttle ([429], capacity, or a
      transient class) that stated no usable [Retry-After] (absent, zero,
      negative, NaN): the signal is real even without a duration
      (RFC-provider-path-rest §3.3). Also the lower clamp of
      {!rate_limit_backoff_cap_sec}. Fixed at [60.0]; not env-configurable. *)

  val rate_limit_backoff_cap_sec : float
  (** The longest a path rests after a provider refusal, and the rest of a
      hard quota that stated no end (RFC-provider-path-rest §3.3). Clamped to
      [{!rate_limit_backoff_floor_sec}, 3600.0]; env
      [MASC_KEEPER_RATE_LIMIT_BACKOFF_CAP_SEC], default [900.0]. A keeper
      waits for a rest only when the path it would send next is resting. *)
  val stream_idle_failsafe_floor_sec : float
  (** Resolved runtime fallback used only when the explicit idle timeout is
      absent. Kept here so runtime execution and operator projection share one
      value. *)


  (** Env names of the four turn budgets. The readers below, the resolved
      layer's source attribution and the suites that declare a budget use
      these, never a re-spelled literal; the settings panel's projector
      still names them as literals. *)

  val stream_idle_timeout_env_key : string
  val first_event_timeout_env_key : string
  val body_timeout_env_key : string
  val provider_call_deadline_env_key : string

  val stream_idle_timeout_sec : unit -> float option
  (** Explicit streaming-provider idle-gap timeout as the operator wrote it.
      [None] means no explicit value (the resolved layer substitutes
      {!stream_idle_failsafe_floor_sec}, RFC-0345); MASC does not infer a
      timeout from provider/model kind. A configured value must be finite,
      strictly positive and at most {!provider_call_deadline_max_sec}: a
      budget longer than the longest no-progress threshold could never be
      allowed by any threshold, so it is refused where it is read rather
      than at every boot by the freeze rule. Otherwise configuration loading
      raises {!Env_config_core.Config_error}. *)

  val first_event_failsafe_floor_sec : float
  (** Resolved runtime fallback used only when the explicit first-event
      timeout is absent. Kept beside {!stream_idle_failsafe_floor_sec} so
      runtime execution and operator projection share one value. *)

  val first_event_timeout_sec : unit -> float option
  (** Explicit streaming-provider first-event (TTFT/prefill) timeout. Bounds
      only the wait for the provider's first token-bearing event (an opening
      frame such as Responses [response.created] does not end it);
      {!stream_idle_timeout_sec} bounds inter-line gaps after it
      (RFC-AC-037). [None] means no explicit
      value (the resolved layer substitutes the fail-safe floor). A configured
      value must be finite, strictly positive and at most
      {!provider_call_deadline_max_sec}, as for {!stream_idle_timeout_sec},
      or configuration loading raises {!Env_config_core.Config_error}. *)

  val body_timeout_min_sec : float
  val body_timeout_max_sec : float
  (** The declared range of {!body_timeout_sec_override}, in seconds. The
      settings registry projects and validates against these; the reader
      refuses a value outside them. *)

  val body_timeout_sec_override : unit -> float option
  (** Total HTTP body-consumption deadline for non-streaming AGENT_CORE
      completion calls, read on every call from the environment (the setting
      has no runtime.toml key). [None] (unset) leaves the runtime builder wire
      untouched. [Some s] forwards to [Builder.with_body_timeout]: it bounds
      a non-streaming completion's round trip, and the count-tokens
      measurement an exact-fit binding makes before either kind of
      completion. A streaming completion itself is bounded by
      {!first_event_timeout_sec} and {!stream_idle_timeout_sec} (the
      operator's values or their floors) and by the attempt watchdog. A
      declared value that is not a finite positive number of seconds within
      the declared range raises {!Env_config_core.Config_error}.

      Env: [MASC_KEEPER_BODY_TIMEOUT_SEC]. *)

  val provider_call_deadline_failsafe_floor_sec : float
  (** Resolved runtime fallback for the provider-call no-progress threshold
      when neither env nor runtime.toml declares one. Kept beside the two
      stream floors so runtime execution and operator projection share one
      value. *)

  val provider_call_deadline_min_sec : float
  val provider_call_deadline_max_sec : float
  (** The declared range of {!provider_call_deadline_sec_override}, in
      seconds. The settings registry projects and validates against these;
      the reader refuses a value outside them, so the environment and
      runtime.toml give one answer. *)

  val provider_call_deadline_sec_override : unit -> float option
  (** The keeper's no-progress threshold for a provider call attempt
      (#27349, #28417), read on every call (env, then the runtime.toml boot
      override). [None] (unset) means no explicit value; the resolved layer
      substitutes {!provider_call_deadline_failsafe_floor_sec}. A declared
      value that is not a finite positive number of seconds within the
      declared range raises {!Env_config_core.Config_error}.

      Env: [MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC]. *)

end

(** {1 gRPC heartbeat reconnect} *)

module KeeperGrpc : sig
  val reconnect_backoff_sec : float
end

(** {1 Proactive generation} *)

module KeeperProactive : sig
  val stage_timing_ring_size : int
end

(** {1 Dashboard health thresholds} *)

module DashboardHealth : sig
  val runtime_warning_ctx_ratio : float
end

(** {1 Peer artifact handoff} *)

module KeeperPeerArtifact : sig
  val max_bytes : unit -> int
end
