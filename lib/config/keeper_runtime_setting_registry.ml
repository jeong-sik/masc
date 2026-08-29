type value_kind =
  | Boolean
  | Integer
  | Float
  | String

type value_range =
  | Unbounded
  | Integer_range of
      { min_inclusive : int option
      ; max_inclusive : int option
      }
  | Float_range of
      { min_inclusive : float option
      ; min_exclusive : float option
      ; max_inclusive : float option
      }

type reload_class =
  | Hot
  | Next_turn
  | Next_cycle
  | Fiber_restart
  | Process_restart

type exposure =
  | Toml_and_env of string
  | Env_only

type lifecycle =
  | Active
  | Retired of
      { reason : string
      ; replacement : string option
      }

type setting =
  { env_name : string
  ; exposure : exposure
  ; value_kind : value_kind
  ; value_range : value_range
  ; default_display : string
  ; reload_class : reload_class
  ; consumers : string list
  ; category : string
  ; description : string
  ; lifecycle : lifecycle
  }

let int_range ?min ?max () = Integer_range { min_inclusive = min; max_inclusive = max }

let float_range ?min ?min_exclusive ?max () =
  Float_range
    { min_inclusive = min; min_exclusive; max_inclusive = max }
;;

let setting
    ?(range = Unbounded)
    ?(reload_class = Process_restart)
    ?(lifecycle = Active)
    ~env_name
    ~exposure
    ~value_kind
    ~default
    ~consumers
    ~category
    description
  =
  { env_name
  ; exposure
  ; value_kind
  ; value_range = range
  ; default_display = default
  ; reload_class
  ; consumers
  ; category
  ; description
  ; lifecycle
  }
;;

let retired ?replacement reason = Retired { reason; replacement }

(* Keep rows grouped by operator-facing category and TOML namespace.  Entries
   whose TOML contract was removed remain here as [Retired] so boot/save
   validation can explain the removal instead of treating a stale key as a
   forward-compatible extension. *)
let all =
  [ setting
      ~env_name:"MASC_KEEPER_BOOTSTRAP_ENABLED"
      ~exposure:(Toml_and_env "bootstrap.enabled")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Keeper_lifecycle_gate_env"; "server bootstrap" ]
      ~category:"bootstrap"
      "Enable startup keeper auto-bootstrap"
  ; setting
      ~range:(int_range ~min:4096 ())
      ~env_name:"MASC_KEEPER_SPAWN_OUTPUT_BUFFER_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"1048576"
      ~consumers:[ "Keeper_agent_run spawn registry" ]
      ~category:"spawn"
      "Bytes of each spawned process stream kept for reading"
  ; setting
      ~range:(float_range ~min:0.05 ())
      ~env_name:"MASC_KEEPER_BOOTSTRAP_LAZY_STARTUP_POLL_INTERVAL_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.25"
      ~consumers:[ "Server_bootstrap_loops lazy-startup poll" ]
      ~category:"bootstrap"
      "Lazy-startup completion poll interval in seconds"
  ; setting
      ~range:(float_range ~min:0.05 ())
      ~env_name:"MASC_KEEPER_BOOTSTRAP_LISTENER_RETRY_INTERVAL_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.25"
      ~consumers:[ "Server_bootstrap_loops lifecycle-listener retry" ]
      ~category:"bootstrap"
      "Keeper lifecycle-listener retry interval in seconds"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~env_name:"MASC_KEEPER_BOOTSTRAP_POST_STARTUP_SETTLE_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"5.0"
      ~consumers:[ "Server_bootstrap_loops post-startup settle" ]
      ~category:"bootstrap"
      "Delay between lazy startup completion and keeper bootstrap"
  ; setting
      ~env_name:"MASC_KEEPER_REACTIVE_ENABLED"
      ~exposure:(Toml_and_env "reactive.enabled")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Keeper_lifecycle_gate_env"; "Keeper_world_observation" ]
      ~category:"lifecycle"
      "Global kill-switch for reactive keeper turns"
  ; setting
      ~env_name:"MASC_KEEPER_PROACTIVE_ENABLED"
      ~exposure:(Toml_and_env "proactive.enabled")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Keeper_lifecycle_gate_env"; "Keeper_world_observation" ]
      ~category:"lifecycle"
      "Global kill-switch for scheduled proactive keeper turns"
  ; setting
      ~env_name:"MASC_KEEPER_AUTONOMOUS_ENABLED"
      ~exposure:(Toml_and_env "autonomous.enabled")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Keeper_lifecycle_gate_env"; "Keeper_activation_readiness" ]
      ~category:"lifecycle"
      "Global kill-switch for autonomous keeper activation"
  ; setting
      ~env_name:"MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT"
      ~exposure:(Toml_and_env "autonomous.wake_prompt")
      ~value_kind:String
      ~default:"Continue."
      ~reload_class:Next_turn
      ~consumers:[ "Keeper_unified_prompt" ]
      ~category:"lifecycle"
      "User message an autonomous turn is woken with, before any keeper override"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~lifecycle:
        (retired
           "No runtime reader consumed this overlay; retaining it fabricated operator control")
      ~env_name:"MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC"
      ~exposure:(Toml_and_env "autonomous.fairness_cooldown_sec")
      ~value_kind:Float
      ~default:"(removed)"
      ~consumers:[]
      ~category:"lifecycle"
      "Removed autonomous fairness cooldown overlay"
  ; setting
      ~range:(int_range ~min:1 ())
      ~env_name:"MASC_KEEPER_HEARTBEAT_INTERVAL_SEC"
      ~exposure:(Toml_and_env "heartbeat.interval_sec")
      ~value_kind:Integer
      ~default:"300"
      ~consumers:[ "Env_config_keeper.KeeperKeepalive"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Keeper heartbeat cycle interval in seconds"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~lifecycle:
        (retired
           "No runtime reader consumed this window; the freshness clock it was meant to bound had no reader either")
      ~env_name:"MASC_KEEPER_MAX_SILENCE_SEC"
      ~exposure:(Toml_and_env "heartbeat.max_silence_sec")
      ~value_kind:Float
      ~default:"(removed)"
      ~consumers:[]
      ~category:"heartbeat"
      "Removed workspace presence proof age overlay"
  ; setting
      ~range:(int_range ~min:15 ~max:3600 ())
      ~env_name:"MASC_KEEPER_SNAPSHOT_SEC"
      ~exposure:(Toml_and_env "heartbeat.snapshot_sec")
      ~value_kind:Integer
      ~default:"300"
      ~consumers:[ "Env_config_keeper.KeeperRuntime"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Keepalive snapshot interval in seconds"
  ; setting
      ~env_name:"MASC_KEEPER_WORK_AS_HEARTBEAT"
      ~exposure:(Toml_and_env "heartbeat.work_as_heartbeat")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Env_config_keeper.WorkAsHeartbeat"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Count successful workspace work heartbeat as presence proof"
  ; setting
      ~range:(float_range ~min:0.1 ~max:10.0 ())
      ~env_name:"MASC_KEEPER_SLEEP_CHUNK_SEC"
      ~exposure:(Toml_and_env "heartbeat.sleep_chunk_sec")
      ~value_kind:Float
      ~default:"0.5"
      ~consumers:[ "Env_config_keeper.KeeperKeepalive"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Interruptible heartbeat sleep chunk in seconds"
  ; setting
      ~range:(int_range ~min:1 ())
      ~lifecycle:
        (retired
           "No heartbeat or board consumer read this value; wake capacity is owned by the durable queue")
      ~env_name:"MASC_KEEPER_BOARD_WAKEUP_MAX"
      ~exposure:(Toml_and_env "heartbeat.board_wakeup_max")
      ~value_kind:Integer
      ~default:"(removed)"
      ~consumers:[]
      ~category:"heartbeat"
      "Removed board wakeup overlay"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~env_name:"MASC_KEEPER_DURABLE_QUEUE_STALE_SEC"
      ~exposure:(Toml_and_env "health.durable_queue_stale_sec")
      ~value_kind:Float
      ~default:"0.0"
      ~consumers:[ "Env_config_keeper.KeeperHealth"; "Server_health" ]
      ~category:"health"
      "Durable queue backlog age before health degrades"
  ; setting
      ~env_name:"MASC_KEEPER_WIRE_CAPTURE"
      ~exposure:(Toml_and_env "wire_capture.enabled")
      ~value_kind:Boolean
      ~default:"false"
      ~consumers:[ "Env_config_keeper.KeeperWireCapture"; "Keeper wire capture" ]
      ~category:"diagnostics"
      "Enable diagnostic provider wire capture"
  ; (* Sized in TOML beside the switch that turns the feature on. These two were
       [Env_only] while [wire_capture.enabled] was [Toml_and_env], so the table
       accepted one key and made its siblings a boot FATAL: [wire_capture] is an
       owned namespace, so [max_bytes] resolved to no setting and was rejected
       as unknown. An operator who enabled capture in TOML and then tried to
       size it there took the server down, and the recovery was to comment the
       keys out and reach for env vars instead.

       Both are bounded diagnostic budgets — the range below is enforced on
       either path — and the consequential switch, whether raw provider payloads
       are captured at all, was already operator-editable here. The asymmetry
       was in how the three were declared, not in what they do. *)
    setting
      ~range:(int_range ~min:1 ~max:30 ())
      ~env_name:"MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS"
      ~exposure:(Toml_and_env "wire_capture.retention_days")
      ~value_kind:Integer
      ~default:"3"
      ~consumers:[ "Env_config_keeper.KeeperWireCapture"; "Keeper wire capture retention" ]
      ~category:"diagnostics"
      "Wire-capture retention in days"
  ; setting
      ~range:(int_range ~min:1 ~max:1073741824 ())
      ~env_name:"MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES"
      ~exposure:(Toml_and_env "wire_capture.max_bytes")
      ~value_kind:Integer
      ~default:"67108864"
      ~consumers:[ "Env_config_keeper.KeeperWireCapture"; "Keeper wire capture retention" ]
      ~category:"diagnostics"
      "Maximum active and retained wire-capture bytes"
  ; setting
      ~env_name:"MASC_KEEPER_DEBUG"
      ~exposure:(Toml_and_env "debug.enabled")
      ~value_kind:Boolean
      ~default:"false"
      ~consumers:[ "Env_config_keeper.KeeperRuntime"; "Keeper logging" ]
      ~category:"diagnostics"
      "Enable keeper debug logging"
  ; setting
      ~range:(int_range ~min:10 ~max:2000 ())
      ~env_name:"MASC_KEEPER_BATCH_LIMIT"
      ~exposure:(Toml_and_env "turn.batch_limit")
      ~value_kind:Integer
      ~default:"200"
      ~consumers:[ "Keeper_config.keeper_batch_limit"; "Keeper unified turn" ]
      ~category:"turn"
      "Maximum batch size processed by one keeper cycle"
  ; setting
      ~range:(float_range ~min:0.0 ~max:2.0 ())
      ~env_name:"MASC_KEEPER_UNIFIED_TEMP"
      ~exposure:(Toml_and_env "turn.temperature")
      ~value_kind:Float
      ~default:"0.4"
      ~consumers:[ "Keeper_config.keeper_unified_temperature"; "Runtime_inference" ]
      ~category:"turn"
      "Fallback sampling temperature for keeper turns"
  ; setting
      ~range:(int_range ~min:256 ~max:262144 ())
      ~lifecycle:
        (retired
           ~replacement:"models.<id>.capabilities.max-output-tokens"
           "The fallback getter had no production caller; runtime model capabilities own this limit")
      ~env_name:"MASC_KEEPER_UNIFIED_MAX_TOKENS"
      ~exposure:(Toml_and_env "turn.max_output_tokens")
      ~value_kind:Integer
      ~default:"(removed)"
      ~consumers:[]
      ~category:"turn"
      "Removed global keeper output-token fallback"
  ; setting
      ~env_name:"MASC_KEEPER_ENABLE_THINKING"
      ~exposure:(Toml_and_env "turn.enable_thinking")
      ~value_kind:Boolean
      ~default:"false"
      ~consumers:[ "Keeper_config.keeper_enable_thinking"; "Keeper_agent_run" ]
      ~category:"turn"
      "Pass the thinking-mode request to the selected runtime"
  ; setting
      ~range:(float_range ~min_exclusive:0.0 ())
      ~env_name:"MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"
      ~exposure:(Toml_and_env "turn.stream_idle_timeout_sec")
      ~value_kind:Float
      ~default:"(failsafe 600)"
      ~consumers:[ "Keeper_runtime_resolved"; "Runtime_agent_context" ]
      ~category:"turn"
      "Streaming provider inter-line idle timeout"
  ; setting
      ~range:(float_range ~min_exclusive:0.0 ())
      ~env_name:"MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC"
      ~exposure:(Toml_and_env "turn.first_event_timeout_sec")
      ~value_kind:Float
      ~default:"(failsafe 600)"
      ~consumers:[ "Keeper_runtime_resolved"; "Runtime_agent_context" ]
      ~category:"turn"
      "Streaming provider first-event (TTFT/prefill) timeout"
  ; setting
      ~range:(float_range ~min:30.0 ~max:3600.0 ())
      ~env_name:"MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC"
      ~exposure:(Toml_and_env "turn.provider_call_deadline_sec")
      ~value_kind:Float
      ~default:"(none)"
      ~consumers:[ "Keeper_runtime_resolved"; "Keeper_agent_run provider deadline" ]
      ~category:"turn"
      "Wall-clock deadline for one provider call attempt"
  ; setting
      ~range:(float_range ~min:10.0 ~max:600.0 ())
      ~lifecycle:
        (retired
           "The public getter had no production caller and therefore never changed CLI execution")
      ~env_name:"MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC"
      ~exposure:(Toml_and_env "turn.cli_subprocess_idle_sec")
      ~value_kind:Float
      ~default:"(removed)"
      ~consumers:[]
      ~category:"turn"
      "Removed CLI subprocess idle overlay"
  ; setting
      ~range:(int_range ~min:1 ())
      ~lifecycle:
        (retired
           "No runtime admission or turn executor consumed the mapped value")
      ~env_name:"MASC_KEEPER_TURN_CAPACITY_LIMIT"
      ~exposure:(Toml_and_env "turn.capacity_limit")
      ~value_kind:Integer
      ~default:"(removed)"
      ~consumers:[]
      ~category:"turn"
      "Removed turn capacity overlay"
  ; setting
      ~range:(float_range ~min:10.0 ~max:600.0 ())
      ~env_name:"MASC_KEEPER_BODY_TIMEOUT_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"(none)"
      ~consumers:[ "Keeper_runtime_resolved"; "Runtime_agent_context sync body reader" ]
      ~category:"turn"
      "Non-streaming provider response-body deadline"
  ; setting
      ~range:(float_range ~min:0.1 ())
      ~env_name:"MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"2.0"
      ~consumers:[ "Keeper_crash_persistence drain fiber" ]
      ~category:"turn"
      "Crash persistence drain interval in seconds"
  ; setting
      ~range:(int_range ~min:10 ~max:1000 ())
      ~env_name:"MASC_KEEPER_STAGE_TIMING_RING_SIZE"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"100"
      ~consumers:[ "Keeper proactive stage timing" ]
      ~category:"turn"
      "Stage timing telemetry ring capacity"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~env_name:"MASC_KEEPER_SUPERVISOR_SWEEP_SEC"
      ~exposure:(Toml_and_env "supervisor.sweep_sec")
      ~value_kind:Float
      ~default:"30.0"
      ~consumers:[ "Env_config_keeper_supervisor"; "Keeper_supervisor" ]
      ~category:"supervisor"
      "Supervisor sweep interval in seconds"
  ; setting
      ~range:(int_range ~min:0 ())
      ~env_name:"MASC_KEEPER_METRICS_MAX_BYTES"
      ~exposure:(Toml_and_env "metrics.max_bytes")
      ~value_kind:Integer
      ~default:"10485760"
      ~consumers:[ "Env_config_keeper.KeeperMetrics"; "Keeper_metrics" ]
      ~category:"metrics"
      "Metrics file size before rotation"
  ; setting
      ~range:(int_range ~min:0 ())
      ~env_name:"MASC_KEEPER_METRICS_MAX_ROTATED"
      ~exposure:(Toml_and_env "metrics.max_rotated")
      ~value_kind:Integer
      ~default:"1"
      ~consumers:[ "Env_config_keeper.KeeperMetrics"; "Keeper_metrics" ]
      ~category:"metrics"
      "Number of rotated metrics files retained"
  ; setting
      ~range:(int_range ~min:1 ())
      ~env_name:"MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"3"
      ~consumers:[ "Env_config_keeper.KeeperMemoryOs"; "Keeper memory librarian" ]
      ~category:"memory"
      "Turns between memory librarian extraction attempts"
  ; setting
      ~range:(int_range ~min:1 ())
      ~env_name:"MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_MESSAGES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"24"
      ~consumers:[ "Env_config_keeper.KeeperMemoryOs"; "Keeper memory librarian" ]
      ~category:"memory"
      "Recent-message window for memory librarian extraction"
  ; setting
      ~range:(int_range ~min:1 ())
      ~env_name:"MASC_KEEPER_MEMORY_OS_RECALL_FACTS_MAX_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"65536"
      ~consumers:[ "Env_config_keeper.KeeperMemoryOs"; "Keeper memory recall" ]
      ~category:"memory"
      "Maximum bytes of recalled memory facts injected into a turn"
  ; setting
      ~reload_class:Next_turn
      ~env_name:"MASC_KEEPER_MEMORY_OS_RECALL"
      ~exposure:Env_only
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Env_config_keeper.KeeperMemoryOs"; "Keeper memory recall" ]
      ~category:"memory"
      "Enable memory recall prompt injection"
  ; setting
      ~reload_class:Next_turn
      ~env_name:"MASC_KEEPER_MEMORY_OS_LIBRARIAN"
      ~exposure:Env_only
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Env_config_keeper.KeeperMemoryOs"; "Keeper memory librarian" ]
      ~category:"memory"
      "Enable post-turn memory librarian extraction"
  ; setting
      ~range:(int_range ~min:1 ~max:10485760 ())
      ~env_name:"MASC_KEEPER_VISION_MAX_IMAGE_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"5242880"
      ~consumers:[ "Keeper vision tool" ]
      ~category:"media"
      "Maximum image bytes accepted by the vision tool"
  ; setting
      ~range:(int_range ~min:4096 ~max:131072 ())
      ~env_name:"MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS"
      ~exposure:(Toml_and_env "vision.max_output_tokens")
      ~value_kind:Integer
      ~default:"65536"
      ~consumers:[ "Keeper vision tool" ]
      ~category:"media"
      "Output-token budget for the vision tool, shared by reasoning and answer"
  ; setting
      ~range:(float_range ~min:0.0 ~max:5.0 ())
      ~env_name:"MASC_KEEPER_VISION_CANDIDATE_BACKOFF_BASE_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.05"
      ~consumers:[ "Keeper vision runtime failover" ]
      ~category:"media"
      "Base delay between vision runtime candidates"
  ; setting
      ~range:(float_range ~min:0.0 ~max:30.0 ())
      ~env_name:"MASC_KEEPER_VISION_CANDIDATE_BACKOFF_MAX_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.25"
      ~consumers:[ "Keeper vision runtime failover" ]
      ~category:"media"
      "Maximum delay between vision runtime candidates"
  ; setting
      ~range:(int_range ~min:1 ~max:52428800 ())
      ~env_name:"MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"10485760"
      ~consumers:[ "Keeper generated-media store" ]
      ~category:"media"
      "Maximum bytes accepted for one generated-media artifact"
  ; setting
      ~range:(int_range ~min:1 ~max:5368709120 ())
      ~env_name:"MASC_KEEPER_GENERATED_MEDIA_DIR_MAX_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"524288000"
      ~consumers:[ "Keeper generated-media cleanup" ]
      ~category:"media"
      "Maximum retained generated-media directory bytes"
  ; setting
      ~range:(float_range ~min:1.0 ~max:2592000.0 ())
      ~env_name:"MASC_KEEPER_GENERATED_MEDIA_RETENTION_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"86400.0"
      ~consumers:[ "Keeper generated-media cleanup" ]
      ~category:"media"
      "Maximum generated-media artifact age in seconds"
  ; setting
      ~range:(float_range ~min:1.0 ~max:60.0 ())
      ~env_name:"MASC_KEEPER_GRPC_RECONNECT_BACKOFF_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"5.0"
      ~consumers:[ "Keeper gRPC heartbeat client" ]
      ~category:"transport"
      "Backoff between keeper gRPC reconnect attempts"
  ; setting
      ~env_name:"MASC_SEARXNG_URL"
      ~exposure:(Toml_and_env "web_search.searxng_url")
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "SearXNG base URL"
  ; setting
      ~env_name:"MASC_WEB_SEARCH_PROVIDER"
      ~exposure:(Toml_and_env "web_search.provider")
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search provider override"
  ; setting
      ~env_name:"MASC_WEB_SEARCH_PROVIDER_ORDER"
      ~exposure:(Toml_and_env "web_search.provider_order")
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search provider fallback order"
  ; setting
      ~env_name:"MASC_WEB_SEARCH_FALLBACKS"
      ~exposure:(Toml_and_env "web_search.fallbacks")
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search fallback provider list"
    (* Provider credentials are Env_only on purpose: runtime.toml is
       committed, so secrets never gain a TOML key. Presence of a key
       admits its provider into the search chain. *)
  ; setting
      ~env_name:"BRAVE_SEARCH_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Brave Search API key (admits the brave and brave_llm_context providers)"
  ; setting
      ~env_name:"TAVILY_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Tavily API key (admits the tavily provider)"
  ; setting
      ~env_name:"EXA_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Exa API key (admits the exa provider)"
  ; setting
      ~env_name:"BING_SEARCH_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Bing Search API key (admits the bing_api provider)"
  ; setting
      ~env_name:"AZURE_BING_SEARCH_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Azure-issued Bing Search API key (same admission as BING_SEARCH_API_KEY)"
  ; setting
      ~env_name:"OLLAMA_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Ollama account API key (admits the ollama provider)"
  ; setting
      ~range:(int_range ~min:1 ~max:60 ())
      ~env_name:"MASC_WEB_SEARCH_TIMEOUT_SEC"
      ~exposure:(Toml_and_env "web_search.timeout_sec")
      ~value_kind:Integer
      ~default:"15"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search request timeout in seconds"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~env_name:"MASC_WEB_SEARCH_CACHE_TTL_SEC"
      ~exposure:(Toml_and_env "web_search.cache_ttl_sec")
      ~value_kind:Float
      ~default:"30.0"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search result cache TTL in seconds"
  ]
;;

let is_active = function
  | { lifecycle = Active; _ } -> true
  | { lifecycle = Retired _; _ } -> false
;;

let active = List.filter is_active all

let toml_key_opt setting =
  match setting.exposure with
  | Toml_and_env key -> Some key
  | Env_only -> None
;;

let active_toml =
  List.filter (fun row -> Option.is_some (toml_key_opt row)) active
;;

let active_toml_mappings =
  List.filter_map
    (fun row -> Option.map (fun key -> key, row.env_name) (toml_key_opt row))
    active_toml
;;

let find_by_toml_key key =
  List.find_opt
    (fun row ->
       match toml_key_opt row with
       | Some candidate -> String.equal candidate key
       | None -> false)
    all
;;

let value_kind_label = function
  | Boolean -> "boolean"
  | Integer -> "integer"
  | Float -> "float"
  | String -> "string"
;;

let value_range_label = function
  | Unbounded -> "unbounded"
  | Integer_range { min_inclusive; max_inclusive } ->
    Printf.sprintf
      "[%s, %s]"
      (Option.fold ~none:"-inf" ~some:string_of_int min_inclusive)
      (Option.fold ~none:"+inf" ~some:string_of_int max_inclusive)
  | Float_range { min_inclusive; min_exclusive; max_inclusive } ->
    let lower =
      match min_inclusive, min_exclusive with
      | Some value, None -> Printf.sprintf "[%g" value
      | None, Some value -> Printf.sprintf "(%g" value
      | None, None -> "(-inf"
      | Some _, Some _ -> "(invalid"
    in
    Printf.sprintf
      "%s, %s]"
      lower
      (Option.fold ~none:"+inf" ~some:(Printf.sprintf "%g") max_inclusive)
;;

let reload_class_label = function
  | Hot -> "hot"
  | Next_turn -> "next_turn"
  | Next_cycle -> "next_cycle"
  | Fiber_restart -> "fiber_restart"
  | Process_restart -> "process_restart"
;;

let lifecycle_label = function
  | Active -> "active"
  | Retired _ -> "retired"
;;

let requires_restart setting =
  match setting.reload_class with
  | Hot | Next_turn | Next_cycle -> false
  | Fiber_restart | Process_restart -> true
;;

let duplicates ~identity rows =
  let counts = Hashtbl.create (List.length rows) in
  List.iter
    (fun row ->
       let key = identity row in
       let next_count =
         match Hashtbl.find_opt counts key with
         | None -> 1
         | Some count -> count + 1
       in
       Hashtbl.replace counts key next_count)
    rows;
  Hashtbl.fold
    (fun key count acc -> if count > 1 then key :: acc else acc)
    counts
    []
;;

let validate_registry () =
  let duplicate_env =
    duplicates ~identity:(fun row -> row.env_name) all
    |> List.map (Printf.sprintf "duplicate env identity: %s")
  in
  let toml_rows = List.filter_map (fun row -> Option.map (fun key -> key, row) (toml_key_opt row)) all in
  let duplicate_toml =
    duplicates ~identity:fst toml_rows
    |> List.map (Printf.sprintf "duplicate TOML identity: %s")
  in
  let consumer_errors =
    active_toml
    |> List.filter (fun row -> row.consumers = [])
    |> List.filter_map (fun row ->
      Option.map
        (Printf.sprintf "active TOML setting has no runtime consumer: %s")
        (toml_key_opt row))
  in
  match duplicate_env @ duplicate_toml @ consumer_errors with
  | [] -> Ok ()
  | errors -> Error errors
;;

let json_of_int_opt = function
  | Some value -> `Int value
  | None -> `Null
;;

let json_of_float_opt = function
  | Some value -> `Float value
  | None -> `Null
;;

let range_to_yojson = function
  | Unbounded -> `Assoc [ "kind", `String "unbounded" ]
  | Integer_range { min_inclusive; max_inclusive } ->
    `Assoc
      [ "kind", `String "integer"
      ; "min_inclusive", json_of_int_opt min_inclusive
      ; "max_inclusive", json_of_int_opt max_inclusive
      ]
  | Float_range { min_inclusive; min_exclusive; max_inclusive } ->
    `Assoc
      [ "kind", `String "float"
      ; "min_inclusive", json_of_float_opt min_inclusive
      ; "min_exclusive", json_of_float_opt min_exclusive
      ; "max_inclusive", json_of_float_opt max_inclusive
      ]
;;

let lifecycle_to_yojson = function
  | Active -> `Assoc [ "state", `String "active" ]
  | Retired { reason; replacement } ->
    `Assoc
      [ "state", `String "retired"
      ; "reason", `String reason
      ; ( "replacement"
        , match replacement with
          | Some value -> `String value
          | None -> `Null )
      ]
;;

let setting_to_yojson row =
  `Assoc
    [ "key", (match toml_key_opt row with Some value -> `String value | None -> `Null)
    ; "env", `String row.env_name
    ; "exposure", `String (match row.exposure with Toml_and_env _ -> "toml_and_env" | Env_only -> "env_only")
    ; "type", `String (value_kind_label row.value_kind)
    ; "range", range_to_yojson row.value_range
    ; "default", `String row.default_display
    ; "reload_class", `String (reload_class_label row.reload_class)
    ; "requires_restart", `Bool (requires_restart row)
    ; "consumers", `List (List.map (fun value -> `String value) row.consumers)
    ; "category", `String row.category
    ; "description", `String row.description
    ; "lifecycle", lifecycle_to_yojson row.lifecycle
    ]
;;

let schema_to_yojson () =
  let toml_count = List.length active_toml in
  let env_only_count = List.length active - toml_count in
  `Assoc
    [ "authority", `String "Keeper_runtime_setting_registry"
    ; "active_count", `Int (List.length active)
    ; "toml_count", `Int toml_count
    ; "env_only_count", `Int env_only_count
    ; "settings", `List (List.map setting_to_yojson all)
    ]
;;
