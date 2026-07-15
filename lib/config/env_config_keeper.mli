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
  val stale_turn_seconds : float
  val max_scan : int
  val lazy_startup_poll_interval_sec : float
  val keeper_listener_retry_interval_sec : float
  val post_startup_settle_sec : float
end
(** {1 Keeper metrics rotation} *)

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
  val domain_pool_enabled : bool
  val sweep_interval_sec : float
  val dead_ttl_sec : float
end

(** {1 Keeper poll intervals} *)

module KeeperPollIntervals : sig
  val crash_persistence_drain_sec : float
end

(** {1 Keeper runtime} *)

module KeeperRuntime : sig
  val debug : bool
  val snapshot_sec : int
end

(** {1 Keeper Memory OS} *)

module KeeperMemoryOs : sig
  (** Env-var names (SSOT). The config-introspection registry and tests must
      reference these constants rather than re-spelling the literals, so a
      knob rename breaks compilation instead of silently drifting. *)

  val recall_env_key : string
  val librarian_timeout_sec_env_key : string
  val librarian_runtime_id_env_key : string
  val gc_env_key : string
  val consolidation_env_key : string
  val consolidation_runtime_id_env_key : string

  val recall_enabled_default : bool
  val librarian_timeout_sec_default : float
  val librarian_runtime_id_default : string option
  val gc_enabled_default : bool
  val consolidation_enabled_default : bool
  val consolidation_runtime_id_default : string option

  val float_default_to_display : float -> string
  (** Render a float default for snapshot display, preserving one trailing
      decimal digit so that values like [600.] display as ["600.0"]. *)

  val recall_enabled : unit -> bool
  val librarian_timeout_sec : unit -> float

  val librarian_runtime_id : unit -> string option
  val gc_enabled : unit -> bool
  val consolidation_enabled : unit -> bool
  val consolidation_runtime_id : unit -> string option
end

(** {1 Keeper dashboard compaction snapshots} *)

module KeeperCompactionSnapshots : sig
  val default_limit : int
  val max_limit : int
  val manifest_scan_min_files : int
  val manifest_scan_limit_multiplier : int
  val manifest_tail_max_lines : int
end

(** {1 Keeper vision tool} *)

module KeeperVision : sig
  (** Raw image-byte budget for [analyze_image], clamped to [1, 10 MiB]. *)
  val max_image_bytes : unit -> int

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
  val max_silence_sec : float
end

(** {1 Keeper health policy} *)

module KeeperHealth : sig
  val durable_queue_stale_sec : unit -> float
end

(** {1 Keeper keepalive loop} *)

module KeeperKeepalive : sig
  val interval_sec : int
  val sleep_chunk_sec : float

  val parse_stream_idle_timeout_sec : string -> (float, string) result
  (** Parse the operator-supplied seconds value. This schema parser performs
      no clamping and accepts only finite, strictly positive values. *)

  val stream_idle_timeout_sec : unit -> float option
  (** Explicit streaming-provider idle-gap timeout. [None] means disabled;
      MASC does not infer a timeout from provider/model kind. A configured
      value must be finite and strictly positive or configuration loading
      raises {!Env_config_core.Config_error}. *)

  val body_timeout_sec_override : float option
  (** Total HTTP body-consumption deadline for non-streaming OAS completion
      calls. [None] (env unset) leaves the runtime builder wire untouched.
      [Some s] forwards to [Builder.with_body_timeout] for sync completion
      paths. Streaming paths ignore it and rely on an explicitly configured
      {!stream_idle_timeout_sec} plus attempt liveness observation.

      Env: [MASC_KEEPER_BODY_TIMEOUT_SEC]. Clamp range: [10, 600] s. *)

end

(** {1 gRPC heartbeat reconnect} *)

module KeeperGrpc : sig
  val reconnect_backoff_sec : float
end

(** {1 Proactive generation} *)

module KeeperProactive : sig
  val max_attempts : int
  val stage_timing_ring_size : int
end

(** {1 Context ratio hard cap} *)

(** Absolute ceiling for compaction ratio_gate / handoff threshold
    after multiplier adjustment.  Range: [\[0.80, 0.99\]].  Reached
    qualified ([Env_config_keeper.context_ratio_hard_cap]) by
    {!Keeper_memory_recall} guard sites. *)
val context_ratio_hard_cap : float

(** {1 Dashboard health thresholds} *)

module DashboardHealth : sig
  val ctx_critical : float
  val ctx_warn : float
  val penalty_critical : float
  val penalty_warn : float
  val runtime_warning_ctx_ratio : float
end
