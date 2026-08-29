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
  val enabled : bool
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

  val wake_prompt_opt : unit -> string option
  (** Fleet wake prompt, [None] when unset. Raises
      {!Env_config_core.Config_error} on a set-but-invalid value rather than
      falling back, so a typo surfaces at read time instead of silently
      restoring the default. *)

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

  val recall_env_key : string
  val librarian_env_key : string
  val librarian_cadence_turns_env_key : string
  val librarian_max_messages_env_key : string
  val recall_facts_max_bytes_env_key : string

  val recall_enabled_default : bool
  val librarian_enabled_default : bool
  val librarian_cadence_turns_default : int
  val librarian_max_messages_default : int
  val recall_facts_max_bytes_default : int

  val librarian_config_state : unit -> librarian_config_state
  (** Typed projection of the effective librarian toggle. Blank or absent
      input uses {!librarian_enabled_default}; malformed non-blank input is
      [Invalid] rather than being collapsed into [Disabled]. *)

  val recall_enabled : unit -> bool
  val librarian_cadence_turns : unit -> int
  val librarian_max_messages : unit -> int
  val recall_facts_max_bytes : unit -> int
  (** Maximum UTF-8 bytes for the rendered dynamic fact payload injected by
      Memory OS recall. Floored to 1. *)
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

(** {1 Keeper health policy} *)

module KeeperHealth : sig
  val durable_queue_stale_sec : unit -> float
end

(** {1 Keeper keepalive loop} *)

module KeeperKeepalive : sig
  val interval_sec : int
  val sleep_chunk_sec : float
  val stream_idle_failsafe_floor_sec : float
  (** Resolved runtime fallback used only when the explicit idle timeout is
      absent. Kept here so runtime execution and operator projection share one
      value. *)

  val parse_stream_idle_timeout_sec : string -> (float, string) result
  (** Parse the operator-supplied seconds value. This schema parser performs
      no clamping and accepts only finite, strictly positive values. *)

  val stream_idle_timeout_sec : unit -> float option
  (** Explicit streaming-provider idle-gap timeout. [None] means disabled;
      MASC does not infer a timeout from provider/model kind. A configured
      value must be finite and strictly positive or configuration loading
      raises {!Env_config_core.Config_error}. *)

  val first_event_failsafe_floor_sec : float
  (** Resolved runtime fallback used only when the explicit first-event
      timeout is absent. Kept beside {!stream_idle_failsafe_floor_sec} so
      runtime execution and operator projection share one value. *)

  val first_event_timeout_sec : unit -> float option
  (** Explicit streaming-provider first-event (TTFT/prefill) timeout. Bounds
      only the wait for the FIRST provider event; {!stream_idle_timeout_sec}
      bounds inter-line gaps after it (RFC-AC-037). [None] means no explicit
      value (the resolved layer substitutes the fail-safe floor). A configured
      value must be finite and strictly positive or configuration loading
      raises {!Env_config_core.Config_error}. *)

  val body_timeout_sec_override_live : unit -> float option
  (** Re-reads the env var on every call. [body_timeout_sec_override] is this
      same reader run once at module load; both exist because one surface
      reports what the process booted with and another resolves what is in
      effect now. The parse and the clamp live here only. *)

  val body_timeout_sec_override : float option
  (** Total HTTP body-consumption deadline for non-streaming AGENT_CORE completion
      calls. [None] (env unset) leaves the runtime builder wire untouched.
      [Some s] forwards to [Builder.with_body_timeout] for sync completion
      paths. Streaming paths ignore it and rely on an explicitly configured
      {!stream_idle_timeout_sec} plus attempt liveness observation.

      Env: [MASC_KEEPER_BODY_TIMEOUT_SEC]. Clamp range: [10, 600] s. *)

  val provider_call_deadline_sec_override_live : unit -> float option
  (** Live counterpart of [provider_call_deadline_sec_override], same relation
      as {!body_timeout_sec_override_live}. *)

  val provider_call_deadline_sec_override : float option
  (** Total wall-clock deadline for one provider call attempt, independent
      of streaming progress and covering both streaming and non-streaming
      calls (#27349). [None] (env unset) means no MASC-side enforcement;
      deliberately no failsafe floor, unlike {!stream_idle_timeout_sec}'s
      RFC-0345 fallback.

      Env: [MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC]. Clamp range: [30, 3600] s. *)

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
