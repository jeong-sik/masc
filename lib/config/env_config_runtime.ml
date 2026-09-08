open Env_config_core

(** {1 Session Configuration} *)

module Session = struct
  (** Maximum session age before cleanup (seconds) *)
  let max_age_seconds =
    get_float ~default:3600.0 "MASC_SESSION_MAX_AGE_SEC"

  (** Grace period after SSE disconnect before reaping transport session (seconds).
      Prevents "Unknown Mcp-Session-Id" errors on brief SSE interruptions. *)
  let sse_grace_period_seconds =
    get_float ~default:300.0 "MASC_SESSION_SSE_GRACE_PERIOD_SEC"
end

(** {1 SSE Reconnect Guard} *)

module Sse_connect_guard = struct
  (* The transport read these three with its own Sys.getenv_opt wrappers, which
     is the one place in the server that did not come through this module
     (#28910). The numbers are unchanged and they are not measured against any
     resource boundary; docs/spec/09-server-transport.md described them as
     disabled by default while the code has always shipped them enabled, and
     the live server log holds no session_cooldown or window_limit rejection at
     all. Whether the default should be off is a separate decision from where
     the value is read. *)

  (** Minimum interval between SSE reconnects for one session (seconds).
      [<= 0.0] disables the per-session cooldown. *)
  let reconnect_min_interval_seconds =
    Env_setting.Float_knob.get Sse_reconnect_min_interval_s

  (** Sliding window over which reconnects are counted (seconds).
      [<= 0.0] disables the window limit. *)
  let connect_window_seconds = Env_setting.Float_knob.get Sse_connect_window_s

  (** Reconnects admitted inside one window. [<= 0] disables the window
      limit. *)
  let connect_max_in_window = Env_setting.Int_knob.get Sse_connect_max_in_window

  (* Re-readable twins of the three bindings above.  They exist so a
     test can pin the documented disable semantics — [<= 0], negative
     included — by setting the env-var and calling the thunk, without
     forking a process (the bindings above are fixed at module init).
     They deliberately use the raw [get_float]/[get_int] readers, NOT
     the [*_nonneg] variants: those clamp a negative to the default,
     which would silently turn "disable" into "default cooldown" — the
     exact regression this module's contract forbids (task-534).  The
     transport keeps reading the cached bindings; these thunks are for
     tests and any future hot-reload call site. *)
  module Re_read = struct
    let reconnect_min_interval_seconds () =
      Env_setting.Float_knob.get Sse_reconnect_min_interval_s

    let connect_window_seconds () = Env_setting.Float_knob.get Sse_connect_window_s
    let connect_max_in_window () = Env_setting.Int_knob.get Sse_connect_max_in_window
  end
end

(** {1 Tempo (Polling Interval) Configuration} *)

module Tempo = struct
  (** Polling interval (seconds) published to operator surfaces *)
  let default_interval_seconds =
    get_float ~default:300.0 "MASC_TEMPO_DEFAULT_INTERVAL_SEC"
end

(** {1 Cache Configuration} *)

module Cache = struct
  (** Maximum size of a single cache entry value in bytes (default 100KB) *)
  let max_entry_size =
    get_int ~default:102400 "MASC_CACHE_MAX_ENTRY_SIZE"

  (** Maximum total number of cache entries (default 1000) *)
  let max_entries =
    get_int ~default:1000 "MASC_CACHE_MAX_ENTRIES"
end

(** {1 Executor / Domain Pool Configuration} *)

module Executor = struct
  (** Shared executor worker-domain count override.
      Env: [MASC_EXECUTOR_DOMAIN_COUNT]. Default: unset, use {!Domain_pool}'s
      host-aware recommendation.
      @category Concurrency
      @ops_class operator *)
  (* [get_int_nonneg] keeps the clamp: a negative override reads as the
     default rather than as "no domains". The name and default come from the
     declaration. *)
  let domain_count_override () =
    let n =
      get_int_nonneg
        ~default:(Env_setting.Int_knob.default Executor_domain_count)
        (Env_setting.Int_knob.env_name Executor_domain_count)
    in
    if n <= 0 then None else Some n
  ;;
end

(** {1 Orchestrator Configuration} *)

module Orchestrator = struct
  (** Orchestrator check interval (seconds) *)
  let check_interval_seconds =
    get_float ~default:300.0 "MASC_ORCHESTRATOR_INTERVAL"

  (** Orchestrator agent name *)
  let agent_name =
    get_string ~default:"orchestrator" "MASC_ORCHESTRATOR_AGENT"

  let min_priority =
    max 0 (min 10 (get_int ~default:2 "MASC_ORCHESTRATOR_MIN_PRIORITY"))

  let enabled =
    Feature_flag_registry.get_bool Env_config_core.orchestrator_enabled_env_key
end

(** {1 Local MODEL Server Configuration} *)

(** Local MODEL runtime config (llama-server / any OpenAI-compatible backend).
    Environment variables retain the LLAMA_ prefix for backward compatibility. *)
module Local_runtime = struct
  (** OpenAI-compatible local MODEL server URL *)
  let server_url =
    get_string ~default:Masc_network_defaults.local_llm_default_url "LLAMA_SERVER_URL"

  (** Default worker model override for the local runtime. *)
  let worker_model_opt () =
    Sys.getenv_opt "LLAMA_WORKER_MODEL" |> trim_opt
end

module Ollama = struct
  let server_url =
    get_string ~default:Masc_network_defaults.ollama_default_url "OLLAMA_SERVER_URL"

  let default_model =
    get_string ~default:"" "OLLAMA_DEFAULT_MODEL"
end

(** {1 Voice Bridge Configuration} *)

module Voice = struct
  (** Default Voice MCP server host *)
  let default_host = Masc_network_defaults.masc_http_default_host

  (** Default Voice MCP server port *)
  let default_port = 8936

  (** Voice MCP HTTP request budget (seconds).

      Wraps two [run_voice_status] sites at [voice_bridge.ml:82,139]
      that drive the Voice MCP HTTP API (synthesis upload, file-form
      POST). Both shared the literal [35.0] — a single knob keeps
      uploaded-payload latency tunable fleet-wide for slow-network
      deployments. Floor 1.0s — anything smaller cannot accommodate
      even a localhost HTTP round trip with TLS handshake. *)
  let http_request_timeout_sec =
    Float.max 1.0
      (get_float ~default:35.0 "VOICE_HTTP_REQUEST_TIMEOUT_SEC")

  (** Audio test-tone subprocess budget (seconds).

      Wraps the [run_voice_status] call at [voice_bridge.ml:892] that
      spawns [sox play] for a 0.15s sine sweep. The 2.0s budget
      includes [sox] startup overhead; lowering this risks cutting
      off short tones on cold-start machines. Floor 0.2s prevents
      operators from disabling the tone via misconfiguration. *)
  let audio_test_tone_timeout_sec =
    Float.max 0.2
      (get_float ~default:2.0 "VOICE_AUDIO_TEST_TONE_TIMEOUT_SEC")
end

(** {1 Message GC Configuration} *)

(** {1 Transport Configuration} *)

module Transport = struct
  type h2_mode =
    | Auto
    | H1_only
    | H2_only

  let h2_env_name = "MASC_USE_H2"
  let h2_default = Auto
  let h2_description = "HTTP mode (auto|0|h1_only|1|h2_only)"

  let h2_accepted_values =
    [ "auto", Auto
    ; "0", H1_only
    ; "h1_only", H1_only
    ; "1", H2_only
    ; "h2_only", H2_only
    ]

  (* The vocabulary is closed. Only an absent setting selects [Auto]; a present
     value outside this set is an operator error and stops startup. *)
  let h2_mode_of_string raw =
    match List.assoc_opt raw h2_accepted_values with
    | Some mode -> mode
    | None ->
      raise
        (Env_config_core.Config_error
           (Printf.sprintf
              "malformed env %s=%S (expected %s)"
              h2_env_name
              raw
              (h2_accepted_values |> List.map fst |> String.concat "|")))

  let h2_mode_to_string = function
    | Auto -> "auto"
    | H1_only -> "h1_only"
    | H2_only -> "h2_only"

  (** gRPC server port. Default: 8936. *)
  let grpc_port = get_port ~default:8936 "MASC_GRPC_PORT"

  (** Whether gRPC transport is enabled. Default: true.
      Accessor-shaped reader; listener lifecycle is still decided at boot. *)
  let grpc_enabled () = Feature_flag_registry.get_bool "MASC_GRPC_ENABLED"

  (** gRPC client target address. Derived from grpc_port when unset. *)
  let grpc_target_opt () =
    Sys.getenv_opt "MASC_GRPC_TARGET" |> trim_opt

  (** Whether WebSocket transport is enabled. Default: true.
      Accessor-shaped reader; listener lifecycle is still decided at boot. *)
  let ws_enabled () = Feature_flag_registry.get_bool "MASC_WS_ENABLED"

  (** Whether HTTP serving is isolated to a dedicated OCaml domain (RFC-0204 Phase 3).
      Default: false. *)
  let serving_domain_enabled () =
    Feature_flag_registry.get_bool "MASC_SERVING_DOMAIN_ENABLED"

  type h2_resolution =
    { value : h2_mode
    ; source : Env_config_snapshot_core.effective_source
    }

  let resolve_h2_env () =
    match Sys.getenv_opt h2_env_name with
    | None ->
      { value = h2_default; source = Env_config_snapshot_core.Default }
    | Some raw ->
      { value = h2_mode_of_string raw
      ; source = Env_config_snapshot_core.Environment
      }

  let configured_h2 = Atomic.make None

  let rec configure_h2_from_env () =
    match Atomic.get configured_h2 with
    | Some resolution -> resolution.value
    | None ->
      let resolution = resolve_h2_env () in
      if Atomic.compare_and_set configured_h2 None (Some resolution)
      then resolution.value
      else configure_h2_from_env ()

  let effective_h2_resolution () =
    match Atomic.get configured_h2 with
    | Some resolution -> resolution
    | None -> resolve_h2_env ()

  let effective_h2_mode () = (effective_h2_resolution ()).value

  let h2_snapshot_entry =
    Env_config_snapshot_collector.effective_entry
      ~default:(h2_mode_to_string h2_default)
      ~read:(fun () ->
        let resolution = effective_h2_resolution () in
        h2_mode_to_string resolution.value, resolution.source)
      h2_env_name
      h2_description

  (** Force strict auth for all HTTP endpoints. Default: false.

      Read through the flag registry, which is what the operator-facing flag
      listing reports. A second reader here used Sys.getenv_opt directly with
      its own case-sensitive spelling set, so MASC_HTTP_AUTH_STRICT=TRUE and any
      boot override made the listing and the enforcement disagree. A malformed
      explicit value is rejected because falling back to [false] would disable
      the requested security policy. *)
  let http_auth_strict_env_enabled () =
    Feature_flag_registry.get_bool_strict "MASC_HTTP_AUTH_STRICT"

  (** Startup watchdog timeout, clamped to [30, 600]. Default: 240.
      Re-readable within the process, but operationally a boot-time input. *)
  let startup_watchdog_sec () =
    let v = get_float ~default:240.0 "MASC_STARTUP_WATCHDOG_SEC" in
    Float.max 30.0 (Float.min 600.0 v)
end

(** {1 Board Configuration} *)

module Board = struct
  (** Flush interval for board persistence (seconds). Default: 30. *)
  let flush_interval_sec =
    get_float ~default:30.0 "MASC_BOARD_FLUSH_INTERVAL_SEC"

  (** Capacity of the board flusher inbox (scheduled sweep/flush messages
      enqueued by the sweeper). Single source of truth shared by the
      persistence layer, its [.mli] doc, and the stream creation site.
      Default: 1000.
      @category Concurrency
      @ops_class operator *)
  let flusher_inbox_capacity =
    Env_setting.Int_knob.get Board_flusher_inbox_capacity
end

(** {1 Tool Surface Configuration} *)

module Tools = struct
  (** Tool list page size, clamped to [10, 1024]. Default: 512.
      Re-readable within the process; not a guarantee of shell-level hot reload. *)
  let list_page_size () =
    let v = get_int ~default:512 "MASC_LIST_PAGE_SIZE" in
    max 10 (min 1024 v)

  let web_search_provider_opt () =
    raw_value_opt "MASC_WEB_SEARCH_PROVIDER" |> trim_opt

  let web_search_provider_order_opt () =
    raw_value_opt "MASC_WEB_SEARCH_PROVIDER_ORDER" |> trim_opt

  let web_search_fallbacks_opt () =
    raw_value_opt "MASC_WEB_SEARCH_FALLBACKS" |> trim_opt

  let web_search_timeout_sec () =
    let v = get_int ~default:15 "MASC_WEB_SEARCH_TIMEOUT_SEC" in
    max 1 (min 60 v)

  (* 15 min, matching the Hermes/OpenClaw web-tool cache window. The
     previous 30 s default expired before a keeper research loop could
     even repeat a query inside one turn. *)
  let web_search_cache_ttl_default_sec = 900.0

  let web_search_cache_ttl_sec () =
    let v =
      get_float
        ~default:web_search_cache_ttl_default_sec
        "MASC_WEB_SEARCH_CACHE_TTL_SEC"
    in
    if v < 0.0 then 0.0 else v

end

(** {1 Rate Limit Bucket Configuration} *)

module Rate_bucket = struct
  (** Requests per second. Default: 100. *)
  let rate = get_float ~default:100.0 "MASC_RATE_LIMIT"

  (** Burst capacity. Default: 150. *)
  let burst = get_int ~default:150 "MASC_RATE_BURST"

  (** Per-agent requests per second. Default: 20. *)
  let agent_rate = get_float ~default:20.0 "MASC_AGENT_RATE_LIMIT"

  (** Per-agent burst capacity. Default: 50. *)
  let agent_burst = get_int ~default:50 "MASC_AGENT_RATE_BURST"
end

(** {1 Worker / Local Runtime Configuration} *)

module Worker = struct
  (** Enable local runtime debug logging. Default: false. *)
  let local_runtime_debug =
    Feature_flag_registry.get_bool "MASC_LOCAL_RUNTIME_DEBUG"

  (** Local runtime cooldown (seconds). *)
  let local_runtime_cooldown_sec_opt () =
    Sys.getenv_opt "MASC_LOCAL_RUNTIME_COOLDOWN_SEC" |> trim_opt
end

(** {1 AGENT_CORE SSE Bridge Configuration} *)

module Agent_core_sse = struct
  (** SSE drain interval (seconds). Default: 2.0. *)
  let drain_interval_sec =
    let v = get_float ~default:2.0 "MASC_AGENT_CORE_SSE_DRAIN_INTERVAL_SEC" in
    if v < 0.1 then 2.0 else v
end

(** {1 Lane failover} *)

module Lane = struct
  (** Sticky lane-candidate preference TTL (seconds). After a lane candidate
      succeeds, later turns on the same lane try it first instead of
      re-attempting candidates declared before it; [0] disables stickiness.
      Default: 3600 (1 hour), matching common hourly provider rate-limit
      windows.
      @category Timeouts
      @ops_class operator *)
  let preference_ttl_s () =
    get_float_nonneg ~default:3600.0 "MASC_LANE_PREFERENCE_TTL_S"
end

(** {1 Dashboard Signal Thresholds} *)

module Dashboard = struct
  (** Signal-age guardrail thresholds (seconds).
      Configurable via environment for runtime tuning without recompilation. *)

  (** Duration (seconds) after which a signal is considered stale. Default: 1200 (20 min). *)
  let signal_stale_sec =
    get_float ~default:1200.0 "MASC_DASHBOARD_SIGNAL_STALE_SEC"

  (** Duration (seconds) for borderline "quiet" warning. Default: 600 (10 min). *)
  let signal_quiet_sec =
    get_float ~default:600.0 "MASC_DASHBOARD_SIGNAL_QUIET_SEC"

  (** Duration (seconds) for a signal to count as "live". Default: 300 (5 min). *)
  let signal_live_sec =
    get_float ~default:300.0 "MASC_DASHBOARD_SIGNAL_LIVE_SEC"

  (** Keeper action-age threshold (seconds). Default: 3600 (1 hour). *)
  let keeper_action_stale_sec =
    get_float ~default:3600.0 "MASC_DASHBOARD_KEEPER_ACTION_STALE_SEC"

  (** Keeper context-ratio lifecycle thresholds.
      Higher ratio = closer to context limit = more urgency. *)
  let ctx_handoff_imminent =
    get_float ~default:0.85 "MASC_DASHBOARD_CTX_HANDOFF_IMMINENT"
  let ctx_preparing =
    get_float ~default:0.70 "MASC_DASHBOARD_CTX_PREPARING"
  let ctx_high =
    get_float ~default:0.50 "MASC_DASHBOARD_CTX_HIGH"

  (** Dashboard shell-cache pre-warm timeouts.

      The pre-warm fires once on server bootstrap. It is wrapped in two
      nested timeouts: the inner
      [Dashboard_cache.get_or_compute_with_timeout] budget covers the
      compute step only, while the outer [Eio.Time.with_timeout] also
      covers cache lookup, mutex contention and surrounding bookkeeping.
      The outer budget MUST strictly exceed the inner budget so the inner
      reports "compute timeout" rather than the fiber being killed by
      the outer wrapper. The default 30/35 split preserves the 5s
      headroom that the inline literals encoded.

      Previously hardcoded as inline literals at
      [server_dashboard_http_execution_surfaces.ml:7] (30.0) and
      [server_runtime_bootstrap.ml:1686] (35.0). On slow-disk or
      contended deployments the pre-warm dropped silently and the
      dashboard rendered cold — operators had no env to raise the
      ceiling without a rebuild ("기다려야 할 부분을 안 기다리는"
      pattern). *)
  let shell_prewarm_inner_timeout_sec =
    Float.max 1.0
      (get_float ~default:30.0 "MASC_DASHBOARD_SHELL_PREWARM_TIMEOUT_SEC")

  let shell_prewarm_outer_timeout_sec =
    Float.max 5.0
      (get_float ~default:35.0
         "MASC_DASHBOARD_SHELL_PREWARM_OUTER_TIMEOUT_SEC")

  (** Execution surface compute timeout (light + parameterized).

      Wraps two [Dashboard_cache.get_or_compute_with_timeout] sites at
      [server_dashboard_http_execution_surfaces.ml:437,449] (execution
      light/parameterized). Default 120s preserves the inline literals.
      Floor 5s ensures the budget can complete a typical projection
      hydration even under aggressive operator override. *)
  let execution_timeout_sec =
    Float.max 5.0
      (get_float ~default:120.0 "MASC_DASHBOARD_EXECUTION_TIMEOUT_SEC")

  (** Execution-trust surface compute timeout.

      Wraps [Dashboard_cache.get_or_compute_with_timeout] at
      [server_dashboard_http_execution_surfaces.ml:463] (execution-trust
      score). Default 30s preserves the inline literal. Smaller than
      [execution_timeout_sec] because the trust projection is
      intentionally lighter — keeping the split visible lets operators
      diagnose when trust scoring is the bottleneck vs. the full
      execution surface. *)
  let execution_trust_timeout_sec =
    Float.max 1.0
      (get_float ~default:30.0
         "MASC_DASHBOARD_EXECUTION_TRUST_TIMEOUT_SEC")

  (** Mission card compute timeout.

      Wraps three [Dashboard_cache.get_or_compute_with_timeout] sites at
      [server_dashboard_http_core.ml:624,633,678] (mission projections).
      Default 25s preserves the pre-extraction inline literal. Floor 1s
      protects against degenerate operator config. *)
  let briefing_timeout_sec =
    Float.max 1.0
      (get_float ~default:25.0 "MASC_DASHBOARD_MISSION_TIMEOUT_SEC")

  (** Shell render compute timeout (full path).

      Used by [Dashboard_cache.get_or_compute_with_timeout] for the full
      shell render. Default 16s preserves the pre-extraction literal at
      [server_dashboard_http_core.ml:790]. *)
  let shell_timeout_sec =
    Float.max 1.0
      (get_float ~default:16.0 "MASC_DASHBOARD_SHELL_TIMEOUT_SEC")

  (** Shell render compute timeout (light path).

      Default 8s. Must remain strictly less than [shell_timeout_sec] so
      the split-budget signal (light vs full) stays meaningful: if a
      light render takes longer than the full budget, that means light
      has accidentally taken on full's work. Floor clamps at 0.5s to
      keep the comparison meaningful even under operator override. *)
  let shell_light_timeout_sec =
    Float.max 0.5
      (get_float ~default:8.0 "MASC_DASHBOARD_SHELL_LIGHT_TIMEOUT_SEC")

  (** Maximum wall-clock for a single dashboard render
      ([Dashboard_execution.json_render]).

      Wraps the entire render pipeline including PG stalls and cold-start
      projection hydration. Default 60s preserves the pre-extraction
      literal at [dashboard_execution.ml:204]. Floor 5s ensures even
      aggressive operator overrides leave workspace for cold-start hydration.
      Render budget should comfortably exceed the longest inner compute
      budget (currently [briefing_timeout_sec] = 25s). *)
  let render_timeout_sec =
    Float.max 5.0
      (get_float ~default:60.0 "MASC_DASHBOARD_RENDER_TIMEOUT_SEC")

  (** Full-health snapshot proactive refresh timeout (seconds).

      Caps a single [/health?full=1] cache refresh attempt in
      [Server_routes_http_runtime.start_full_health_snapshot_refresh_loop].
      Default 20s (bumped from 8s) reduces F-6 fan-in tail: make_health_json
      synchronously fans 17 components, and Team BBBB2 observed 27% tail
      at 16s live override (307/24h timeouts). Bumping the floor default
      to 20s is the bridge expected to drop tail to <10% (<50/24h).
      Floor 1s prevents degenerate operator overrides.

      WORKAROUND: This is a cap raise (§4 anti-pattern signature) accepted
      as bridge until structural RFC lands (per-component health cache so
      make_health_json no longer fans 17 sync calls per refresh).
      Removal target: issue #26875 — the replacement RFC does not exist yet,
      so the issue is what carries the obligation. A cap raise whose removal
      target is unnamed does not expire, and the next one cites it as
      precedent. *)
  let full_health_refresh_timeout_sec =
    Float.max 1.0 (Env_setting.Float_knob.get Full_health_refresh_timeout_sec)

  (** Number of consecutive [/health?full=1] cache-refresh failures
      that must accumulate before
      [masc_full_health_refresh_critical_total] is incremented exactly
      once (the counter fires on the edge, not on every subsequent
      failure).  Default 5 matches the observed "still warming"
      threshold in production logs where 1-4 transient timeouts
      typically self-recover.  Floor 1 keeps the counter at least
      reachable.  *)
  let full_health_critical_failure_threshold =
    Stdlib.max 1 (Env_setting.Int_knob.get Full_health_critical_failure_threshold)
end

(** {1 Internal Timers and TTLs}

    Internal cache/GC/flush intervals. Low operational impact but
    centralized here to eliminate scattered magic 300.0/3600.0 literals. *)

module InternalTimers = struct
  (** Dashboard label "quiet" threshold (seconds). Default: 300 (5 min). *)
  let label_quiet_threshold_sec =
    get_float ~default:300.0 "MASC_LABEL_QUIET_THRESHOLD_SEC"

  (** Dashboard label "stuck" threshold (seconds). Default: 900 (15 min). *)
  let label_stuck_threshold_sec =
    get_float ~default:900.0 "MASC_LABEL_STUCK_THRESHOLD_SEC"

  (** Dashboard mission briefing cache TTL (seconds). Default: 300 (5 min). *)
  let briefing_cache_ttl_sec =
    get_float ~default:300.0 "MASC_BRIEFING_CACHE_TTL_SEC"

  (** SSE buffer TTL (seconds). Default: 300 (5 min). *)
  let sse_buffer_ttl_sec =
    get_float ~default:300.0 "MASC_SSE_BUFFER_TTL_SEC"

  (** Operator digest stalled session threshold (seconds). Default: 300 (5 min). *)
  let stalled_session_threshold_sec =
    get_float ~default:300.0 "MASC_STALLED_SESSION_THRESHOLD_SEC"

  (** Repository auto-sync interval (seconds). The repo_sync fiber in
      [server_bootstrap_loops] wakes at this cadence to fetch repositories
      with [auto_sync = true]. Default: 300 (5 min). *)
  let repo_sync_interval_sec =
    let value = Env_setting.Float_knob.get Repo_sync_interval_sec in
    if value > 0.0
    then value
    else Env_setting.Float_knob.default Repo_sync_interval_sec

  (** Rate-limit bucket staleness TTL (seconds). Buckets with no traffic for
      this long are dropped by the maintenance loop. Default: 300 (5 min). Raise
      for longer client quiet periods; lower to free memory faster under
      churn. [Rate_limit.cleanup] takes an int, so this is int-typed. *)
  let rate_limit_bucket_ttl_sec = Env_setting.Int_knob.get Rate_limit_bucket_ttl_sec
end

(** {1 Sidecar reconcile loop}

    Retry/backoff knobs for the connector sidecar lifecycle (#8919). Operator
    override lets us tune backoff without recompilation when a sidecar is
    flapping vs. genuinely offline. See #8930 for the SSOT consolidation. *)

module Sidecar = struct
  (** Backoff window (seconds) between repeated same-generation
      [running + unavailable] start dispatches. Default: 30 (matches the
      inline literal that landed in #8919). *)
  let reconcile_backoff_sec =
    Env_setting.Float_knob.get Sidecar_reconcile_backoff_sec

  (** Subprocess timeout (seconds) for sidecar control commands —
      [stop], [tail], and similar quick housekeeping operations.

      Wraps two [Process_eio.run_argv_with_status] sites at
      [server_routes_http_routes_sidecar.ml:780,835]. Default 5s
      preserves the inline literals; floor 1s prevents an operator
      typo from making every control command return "timeout" before
      the sidecar even handles the signal. *)
  let control_command_timeout_sec =
    Float.max 1.0 (Env_setting.Float_knob.get Sidecar_control_timeout_sec)

  (** Subprocess timeout (seconds) for sidecar Python schema
      generation. Wraps [Process_eio.run_argv_with_status] at
      [server_routes_http_routes_sidecar.ml:882]. Default 10s
      preserves the inline literal; this path runs Python interp +
      schema introspection so it needs more headroom than the
      lightweight control commands. Floor 1s.

      Must satisfy [schema_generation > control_command] — schema
      gen is strictly heavier than control commands, so an operator
      lowering schema budget below the control budget would silently
      reorder the implicit precedence and surprise downstream
      diagnostics. *)
  let schema_generation_timeout_sec =
    Float.max 1.0 (Env_setting.Float_knob.get Sidecar_schema_timeout_sec)
end

module Workspace_file = struct
  (** Maximum bytes served by the IDE workspace file endpoint in one
      response. The route rejects larger files instead of materializing
      them in memory on a server fiber.
      @category Policies
      @ops_class operator *)
  let max_read_bytes =
    max
      1
      (get_int_nonneg
         ~default:(Env_setting.Int_knob.default Workspace_file_max_read_bytes)
         (Env_setting.Int_knob.env_name Workspace_file_max_read_bytes))
end

(** {1 Internal Safety Configuration} *)
