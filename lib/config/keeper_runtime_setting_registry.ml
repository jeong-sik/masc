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

(* How the operator surface reads the value a runtime consumer sees. A
   [Reader] calls the owning typed accessor and renders its result; it may
   raise [Env_config_core.Config_error] for a malformed input. A credential is
   projected as present or absent, never as its value. *)
type effective =
  | Reader of (unit -> string)
  | Credential_presence

type setting =
  { env_name : string
  ; exposure : exposure
  ; effective : effective
  ; value_kind : value_kind
  ; value_range : value_range
  ; default_display : string
  ; reload_class : reload_class
  ; consumers : string list
  ; category : string
  ; description : string
  }

let int_range ?min ?max () = Integer_range { min_inclusive = min; max_inclusive = max }

let float_range ?min ?min_exclusive ?max () =
  Float_range
    { min_inclusive = min; min_exclusive; max_inclusive = max }
;;

let display_bool value = if value then "true" else "false"
let display_int = string_of_int
let display_float value = Printf.sprintf "%g" value

let display_string_option = function
  | Some value -> value
  | None -> "(none)"
;;

let display_float_option = Option.fold ~none:"(none)" ~some:display_float

(* An unset thinking request leaves the selected runtime's provider default in
   place; the row's advertised default and its effective value say so alike. *)
let provider_default_display = "unset (provider default)"

(* The web-search chain admits a provider on the same test, a non-blank
   value. *)
let display_credential_presence = function
  | Some value when String.trim value <> "" -> "(set)"
  | Some _ | None -> "(none)"
;;

let setting
    ?(range = Unbounded)
    ?(reload_class = Process_restart)
    ~effective
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
  ; effective
  ; value_kind
  ; value_range = range
  ; default_display = default
  ; reload_class
  ; consumers
  ; category
  ; description
  }
;;

(* Keep rows grouped by operator-facing category and TOML namespace. A row
   leaves with the contract it described; a key that names a removed row is
   then an unknown key to boot/save validation, like any other. *)
let all =
  [ setting
      ~range:(int_range ~min:4096 ())
      ~effective:(Reader (fun () -> display_int Env_config_keeper.KeeperSpawn.spawn_output_buffer_bytes))
      ~env_name:"MASC_KEEPER_SPAWN_OUTPUT_BUFFER_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"1048576"
      ~consumers:[ "Keeper_agent_run spawn registry" ]
      ~category:"spawn"
      "Bytes of each spawned process stream kept for reading"
  ; setting
      (* The clamp in Env_config_keeper.KeeperLaneGate is [0.001, 600], which
         is what this range repeats. Its doc comment says "(0, 600]"; the code
         is the one an operator meets. *)
      ~range:(float_range ~min:0.001 ~max:600. ())
      ~effective:(Reader (fun () -> display_float (Env_config_keeper.KeeperLaneGate.admission_wait_budget_sec ())))
      ~env_name:"MASC_KEEPER_LANE_ADMISSION_WAIT_BUDGET_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"60"
      ~consumers:[ "Keeper_msg_async submit lane" ]
      ~category:"turn"
      "Seconds a submit waits for its lane before reporting it unavailable"
  ; setting
      ~range:(float_range ~min:0.05 ())
      ~effective:
        (Reader
           (fun () ->
              display_float
                Env_config_keeper.KeeperBootstrap.lazy_startup_poll_interval_sec))
      ~env_name:"MASC_KEEPER_BOOTSTRAP_LAZY_STARTUP_POLL_INTERVAL_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.25"
      ~consumers:[ "Server_bootstrap_loops lazy-startup poll" ]
      ~category:"bootstrap"
      "Lazy-startup completion poll interval in seconds"
  ; setting
      ~range:(float_range ~min:0.05 ())
      ~effective:
        (Reader
           (fun () ->
              display_float
                Env_config_keeper.KeeperBootstrap.keeper_listener_retry_interval_sec))
      ~env_name:"MASC_KEEPER_BOOTSTRAP_LISTENER_RETRY_INTERVAL_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.25"
      ~consumers:[ "Server_bootstrap_loops lifecycle-listener retry" ]
      ~category:"bootstrap"
      "Keeper lifecycle-listener retry interval in seconds"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~effective:(Reader (fun () -> display_float Env_config_keeper.KeeperBootstrap.post_startup_settle_sec))
      ~env_name:"MASC_KEEPER_BOOTSTRAP_POST_STARTUP_SETTLE_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"5.0"
      ~consumers:[ "Server_bootstrap_loops post-startup settle" ]
      ~category:"bootstrap"
      "Delay between lazy startup completion and keeper bootstrap"
  ; setting
      ~effective:(Reader (fun () -> display_bool (Env_config_keeper.KeeperReactive.enabled ())))
      ~env_name:"MASC_KEEPER_REACTIVE_ENABLED"
      ~exposure:(Toml_and_env "reactive.enabled")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Keeper_lifecycle_gate_env"; "Keeper_world_observation" ]
      ~category:"lifecycle"
      "Global kill-switch for reactive keeper turns"
  ; setting
      ~effective:(Reader (fun () -> display_bool (Env_config_keeper.KeeperBootstrap.enabled ())))
      ~env_name:"MASC_KEEPER_AUTONOMOUS_ENABLED"
      ~exposure:(Toml_and_env "autonomous.enabled")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Keeper_lifecycle_gate_env"; "Keeper_activation_readiness" ]
      ~category:"lifecycle"
      "Global switch for automatic Keeper startup and spontaneous turns"
  ; setting
      ~effective:
        (Reader
           (fun () ->
              (* Reports the same string the prompt builder uses, so the settings
                 panel and the turn agree. *)
              Env_config_keeper.KeeperAutonomous.wake_prompt ()))
      ~env_name:"MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT"
      ~exposure:(Toml_and_env "autonomous.wake_prompt")
      ~value_kind:String
      ~default:Env_config_keeper.KeeperAutonomous.default_wake_prompt
      ~reload_class:Next_turn
      ~consumers:[ "Keeper_unified_prompt" ]
      ~category:"lifecycle"
      "User message an autonomous turn is woken with, before any keeper override"
  ; setting
      ~range:(int_range ~min:1 ())
      ~effective:(Reader (fun () -> display_int Env_config_keeper.KeeperKeepalive.interval_sec))
      ~env_name:"MASC_KEEPER_HEARTBEAT_INTERVAL_SEC"
      ~exposure:(Toml_and_env "heartbeat.interval_sec")
      ~value_kind:Integer
      ~default:"300"
      ~consumers:[ "Env_config_keeper.KeeperKeepalive"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Keeper heartbeat cycle interval in seconds"
  ; setting
      ~range:(int_range ~min:15 ~max:3600 ())
      ~effective:(Reader (fun () -> display_int Env_config_keeper.KeeperRuntime.snapshot_sec))
      ~env_name:"MASC_KEEPER_SNAPSHOT_SEC"
      ~exposure:(Toml_and_env "heartbeat.snapshot_sec")
      ~value_kind:Integer
      ~default:"300"
      ~consumers:[ "Env_config_keeper.KeeperRuntime"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Keepalive snapshot interval in seconds"
  ; setting
      ~effective:(Reader (fun () -> display_bool Env_config_keeper.WorkAsHeartbeat.enabled))
      ~env_name:"MASC_KEEPER_WORK_AS_HEARTBEAT"
      ~exposure:(Toml_and_env "heartbeat.work_as_heartbeat")
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Env_config_keeper.WorkAsHeartbeat"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Count successful workspace work heartbeat as presence proof"
  ; setting
      ~range:(float_range ~min:0.1 ~max:10.0 ())
      ~effective:(Reader (fun () -> display_float Env_config_keeper.KeeperKeepalive.sleep_chunk_sec))
      ~env_name:"MASC_KEEPER_SLEEP_CHUNK_SEC"
      ~exposure:(Toml_and_env "heartbeat.sleep_chunk_sec")
      ~value_kind:Float
      ~default:"0.5"
      ~consumers:[ "Env_config_keeper.KeeperKeepalive"; "Keeper_heartbeat_loop" ]
      ~category:"heartbeat"
      "Interruptible heartbeat sleep chunk in seconds"
  ; setting
      ~range:
        (float_range
           ~min:Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec
           ~max:3600.0
           ())
      ~effective:(Reader (fun () -> display_float Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec))
      ~env_name:"MASC_KEEPER_RATE_LIMIT_BACKOFF_CAP_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"900.0"
      ~consumers:
        [ "Env_config_keeper.KeeperKeepalive"
        ; "Keeper_runtime_failure_route"
        ; "Keeper_turn_driver"
        ; "Keeper_heartbeat_loop"
        ]
      ~category:"heartbeat"
      "Fallback cap for provider rests without usable reset hints, in seconds; provider hints are preserved"
  ; setting
      ~effective:(Reader (fun () -> display_bool (Env_config_keeper.KeeperWireCapture.enabled ())))
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
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperWireCapture.retention_days ())))
      ~env_name:"MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS"
      ~exposure:(Toml_and_env "wire_capture.retention_days")
      ~value_kind:Integer
      ~default:"3"
      ~consumers:[ "Env_config_keeper.KeeperWireCapture"; "Keeper wire capture retention" ]
      ~category:"diagnostics"
      "Wire-capture retention in days"
  ; setting
      ~range:(int_range ~min:1 ~max:1073741824 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperWireCapture.max_bytes ())))
      ~env_name:"MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES"
      ~exposure:(Toml_and_env "wire_capture.max_bytes")
      ~value_kind:Integer
      ~default:"67108864"
      ~consumers:[ "Env_config_keeper.KeeperWireCapture"; "Keeper wire capture retention" ]
      ~category:"diagnostics"
      "Maximum active and retained wire-capture bytes"
  ; setting
      ~effective:(Reader (fun () -> display_bool Env_config_keeper.KeeperRuntime.debug))
      ~env_name:"MASC_KEEPER_DEBUG"
      ~exposure:(Toml_and_env "debug.enabled")
      ~value_kind:Boolean
      ~default:"false"
      ~consumers:[ "Env_config_keeper.KeeperRuntime"; "Keeper logging" ]
      ~category:"diagnostics"
      "Enable keeper debug logging"
  ; setting
      ~range:
        (int_range
           ~min:Env_config_keeper.KeeperTurn.batch_limit_min
           ~max:Env_config_keeper.KeeperTurn.batch_limit_max
           ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperTurn.batch_limit ())))
      ~env_name:"MASC_KEEPER_BATCH_LIMIT"
      ~exposure:(Toml_and_env "turn.batch_limit")
      ~value_kind:Integer
      ~default:(display_int Env_config_keeper.KeeperTurn.batch_limit_default)
      ~consumers:[ "Keeper_config.keeper_batch_limit"; "Keeper unified turn" ]
      ~category:"turn"
      "Maximum batch size processed by one keeper cycle"
  ; setting
      ~range:
        (float_range
           ~min:Env_config_keeper.KeeperTurn.temperature_min
           ~max:Env_config_keeper.KeeperTurn.temperature_max
           ())
      ~effective:(Reader (fun () -> display_float (Env_config_keeper.KeeperTurn.temperature ())))
      ~env_name:"MASC_KEEPER_UNIFIED_TEMP"
      ~exposure:(Toml_and_env "turn.temperature")
      ~value_kind:Float
      ~default:(display_float Env_config_keeper.KeeperTurn.temperature_default)
      ~consumers:[ "Keeper_config.keeper_unified_temperature"; "Runtime_inference" ]
      ~category:"turn"
      "Fallback sampling temperature for keeper turns"
  ; setting
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_keeper.KeeperTurn.enable_thinking () with
              | Some enabled -> display_bool enabled
              | None -> provider_default_display)))
      ~env_name:"MASC_KEEPER_ENABLE_THINKING"
      ~exposure:(Toml_and_env "turn.enable_thinking")
      ~value_kind:Boolean
      ~default:provider_default_display
      ~consumers:[ "Keeper_config.keeper_enable_thinking"; "Keeper_agent_run" ]
      ~category:"turn"
      "Pass the thinking-mode request to the selected runtime"
  ; setting
      ~range:
        (float_range
           ~min_exclusive:0.0
           ~max:Env_config_keeper.KeeperKeepalive.provider_call_deadline_max_sec
           ())
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec () with
              | Some value -> display_float value
              | None ->
                display_float
                  Env_config_keeper.KeeperKeepalive.stream_idle_failsafe_floor_sec)))
      ~env_name:Env_config_keeper.KeeperKeepalive.stream_idle_timeout_env_key
      ~exposure:(Toml_and_env "turn.stream_idle_timeout_sec")
      ~value_kind:Float
      ~default:
        (Printf.sprintf
           "(failsafe %g)"
           Env_config_keeper.KeeperKeepalive.stream_idle_failsafe_floor_sec)
      ~consumers:[ "Keeper_runtime_resolved"; "Runtime_agent_context" ]
      ~category:"turn"
      "Streaming provider inter-line idle timeout"
  ; setting
      ~range:
        (float_range
           ~min_exclusive:0.0
           ~max:Env_config_keeper.KeeperKeepalive.provider_call_deadline_max_sec
           ())
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_keeper.KeeperKeepalive.first_event_timeout_sec () with
              | Some value -> display_float value
              | None ->
                display_float
                  Env_config_keeper.KeeperKeepalive.first_event_failsafe_floor_sec)))
      ~env_name:Env_config_keeper.KeeperKeepalive.first_event_timeout_env_key
      ~exposure:(Toml_and_env "turn.first_event_timeout_sec")
      ~value_kind:Float
      ~default:
        (Printf.sprintf
           "(failsafe %g)"
           Env_config_keeper.KeeperKeepalive.first_event_failsafe_floor_sec)
      ~consumers:[ "Keeper_runtime_resolved"; "Runtime_agent_context" ]
      ~category:"turn"
      "Streaming provider first-event (TTFT/prefill) timeout"
  ; setting
      ~range:
        (float_range
           ~min:Env_config_keeper.KeeperKeepalive.provider_call_deadline_min_sec
           ~max:Env_config_keeper.KeeperKeepalive.provider_call_deadline_max_sec
           ())
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override () with
              | Some value -> display_float value
              | None ->
                display_float
                  Env_config_keeper.KeeperKeepalive.provider_call_deadline_failsafe_floor_sec)))
      ~env_name:Env_config_keeper.KeeperKeepalive.provider_call_deadline_env_key
      ~exposure:(Toml_and_env "turn.provider_call_deadline_sec")
      ~value_kind:Float
      ~default:
        (Printf.sprintf
           "(failsafe %g)"
           Env_config_keeper.KeeperKeepalive.provider_call_deadline_failsafe_floor_sec)
      ~consumers:
        [ "Keeper_runtime_resolved"
        ; "Keeper_turn_driver_try_provider attempt watchdog"
        ; "Keeper_provider_subcall"
        ; "Keeper_identity_tools MCP transport"
        ]
      ~category:"turn"
      "No-progress threshold for a provider call attempt and a tool's provider sub-call"
  ; setting
      ~range:
        (float_range
           ~min:Env_config_keeper.KeeperKeepalive.body_timeout_min_sec
           ~max:Env_config_keeper.KeeperKeepalive.body_timeout_max_sec
           ())
      ~effective:
        (Reader
           (fun () ->
              display_float_option
                (Env_config_keeper.KeeperKeepalive.body_timeout_sec_override ())))
      ~env_name:Env_config_keeper.KeeperKeepalive.body_timeout_env_key
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"(none)"
      ~consumers:[ "Keeper_runtime_resolved"; "Runtime_agent_context sync body reader" ]
      ~category:"turn"
      "Non-streaming provider response-body deadline"
  ; setting
      ~range:(float_range ~min:0.1 ())
      ~effective:(Reader (fun () -> display_float Env_config_keeper.KeeperPollIntervals.crash_persistence_drain_sec))
      ~env_name:"MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"2.0"
      ~consumers:[ "Keeper_crash_persistence drain fiber" ]
      ~category:"turn"
      "Crash persistence drain interval in seconds"
  ; setting
      ~range:(int_range ~min:10 ~max:1000 ())
      ~effective:(Reader (fun () -> display_int Env_config_keeper.KeeperProactive.stage_timing_ring_size))
      ~env_name:"MASC_KEEPER_STAGE_TIMING_RING_SIZE"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"100"
      ~consumers:[ "Keeper proactive stage timing" ]
      ~category:"turn"
      "Stage timing telemetry ring capacity"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~effective:(Reader (fun () -> display_float Env_config_keeper.KeeperSupervisor.sweep_interval_sec))
      ~env_name:"MASC_KEEPER_SUPERVISOR_SWEEP_SEC"
      ~exposure:(Toml_and_env "supervisor.sweep_sec")
      ~value_kind:Float
      ~default:"30.0"
      ~consumers:[ "Env_config_keeper_supervisor"; "Keeper_supervisor" ]
      ~category:"supervisor"
      "Supervisor sweep interval in seconds"
  ; setting
      ~range:(int_range ~min:0 ())
      ~effective:(Reader (fun () -> display_int Env_config_keeper.KeeperMetrics.max_file_bytes))
      ~env_name:"MASC_KEEPER_METRICS_MAX_BYTES"
      ~exposure:(Toml_and_env "metrics.max_bytes")
      ~value_kind:Integer
      ~default:"10485760"
      ~consumers:[ "Env_config_keeper.KeeperMetrics"; "Keeper_metrics" ]
      ~category:"metrics"
      "Metrics file size before rotation"
  ; setting
      ~range:(int_range ~min:0 ())
      ~effective:(Reader (fun () -> display_int Env_config_keeper.KeeperMetrics.max_rotated_files))
      ~env_name:"MASC_KEEPER_METRICS_MAX_ROTATED"
      ~exposure:(Toml_and_env "metrics.max_rotated")
      ~value_kind:Integer
      ~default:"1"
      ~consumers:[ "Env_config_keeper.KeeperMetrics"; "Keeper_metrics" ]
      ~category:"metrics"
      "Number of rotated metrics files retained"
  ; setting
      ~reload_class:Next_turn
      ~effective:(Reader (fun () -> display_bool (Env_config_keeper.KeeperMemoryOs.recall_enabled ())))
      ~env_name:"MASC_KEEPER_MEMORY_OS_RECALL"
      ~exposure:Env_only
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Env_config_keeper.KeeperMemoryOs"; "Keeper memory recall" ]
      ~category:"memory"
      "Enable memory recall prompt injection"
  ; setting
      ~reload_class:Next_turn
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_keeper.KeeperMemoryOs.librarian_config_state () with
              | Env_config_keeper.KeeperMemoryOs.Enabled -> "true"
              | Env_config_keeper.KeeperMemoryOs.Disabled -> "false"
              | Env_config_keeper.KeeperMemoryOs.Invalid ->
                raise
                  (Env_config_core.Config_error
                     "MASC_KEEPER_MEMORY_OS_LIBRARIAN is malformed"))))
      ~env_name:"MASC_KEEPER_MEMORY_OS_LIBRARIAN"
      ~exposure:Env_only
      ~value_kind:Boolean
      ~default:"true"
      ~consumers:[ "Env_config_keeper.KeeperMemoryOs"; "Keeper memory librarian" ]
      ~category:"memory"
      "Enable post-turn memory librarian extraction"
  ; setting
      ~range:(int_range ~min:1 ~max:10485760 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperVision.max_image_bytes ())))
      ~env_name:"MASC_KEEPER_VISION_MAX_IMAGE_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"5242880"
      ~consumers:[ "Keeper vision tool" ]
      ~category:"media"
      "Maximum image bytes accepted by the vision tool"
  ; setting
      ~range:(int_range ~min:4096 ~max:131072 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperVision.max_output_tokens ())))
      ~env_name:"MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS"
      ~exposure:(Toml_and_env "vision.max_output_tokens")
      ~value_kind:Integer
      ~default:"65536"
      ~consumers:[ "Keeper vision tool" ]
      ~category:"media"
      "Output-token budget for the vision tool, shared by reasoning and answer"
  ; setting
      ~range:(float_range ~min:0.0 ~max:5.0 ())
      ~effective:(Reader (fun () -> display_float (Env_config_keeper.KeeperVision.candidate_backoff_base_sec ())))
      ~env_name:"MASC_KEEPER_VISION_CANDIDATE_BACKOFF_BASE_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.05"
      ~consumers:[ "Keeper vision runtime failover" ]
      ~category:"media"
      "Base delay between vision runtime candidates"
  ; setting
      ~range:(float_range ~min:0.0 ~max:30.0 ())
      ~effective:(Reader (fun () -> display_float (Env_config_keeper.KeeperVision.candidate_backoff_max_sec ())))
      ~env_name:"MASC_KEEPER_VISION_CANDIDATE_BACKOFF_MAX_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"0.25"
      ~consumers:[ "Keeper vision runtime failover" ]
      ~category:"media"
      "Maximum delay between vision runtime candidates"
  ; setting
      ~range:(int_range ~min:256 ~max:8192 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperVision.max_dimension ())))
      ~env_name:"MASC_KEEPER_VISION_MAX_DIMENSION"
      ~exposure:(Toml_and_env "vision.max_dimension")
      ~value_kind:Integer
      ~default:"1568"
      ~consumers:[ "Keeper_vision_downscale" ]
      ~category:"media"
      "Maximum image dimension (longest edge) sent to vision models before downscaling"
  ; setting
      ~range:(int_range ~min:1 ~max:52428800 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperGeneratedMedia.max_bytes ())))
      ~env_name:"MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"10485760"
      ~consumers:[ "Keeper generated-media store" ]
      ~category:"media"
      "Maximum bytes accepted for one generated-media artifact"
  ; setting
      ~range:(int_range ~min:1 ~max:268435456 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperPeerArtifact.max_bytes ())))
      ~env_name:"MASC_KEEPER_PEER_ARTIFACT_MAX_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"67108864"
      ~consumers:[ "Keeper peer artifact export" ]
      ~category:"media"
      "Maximum bytes a Keeper may hand to a peer as one exported artifact"
  ; setting
      ~range:(int_range ~min:1 ~max:5368709120 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperGeneratedMedia.dir_max_bytes ())))
      ~env_name:"MASC_KEEPER_GENERATED_MEDIA_DIR_MAX_BYTES"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"524288000"
      ~consumers:[ "Keeper generated-media cleanup" ]
      ~category:"media"
      "Maximum retained generated-media directory bytes"
  ; setting
      ~range:(float_range ~min:1.0 ~max:2592000.0 ())
      ~effective:(Reader (fun () -> display_float (Env_config_keeper.KeeperGeneratedMedia.retention_seconds ())))
      ~env_name:"MASC_KEEPER_GENERATED_MEDIA_RETENTION_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"86400.0"
      ~consumers:[ "Keeper generated-media cleanup" ]
      ~category:"media"
      "Maximum generated-media artifact age in seconds"
  ; setting
      ~range:(float_range ~min:1.0 ~max:60.0 ())
      ~effective:(Reader (fun () -> display_float Env_config_keeper.KeeperGrpc.reconnect_backoff_sec))
      ~env_name:"MASC_KEEPER_GRPC_RECONNECT_BACKOFF_SEC"
      ~exposure:Env_only
      ~value_kind:Float
      ~default:"5.0"
      ~consumers:[ "Keeper gRPC heartbeat client" ]
      ~category:"transport"
      "Backoff between keeper gRPC reconnect attempts"
  ; setting
      ~range:(int_range ~min:1 ~max:256 ())
      ~effective:(Reader (fun () -> display_int (Env_config_keeper.KeeperAdmissionBounds.max_events ())))
      ~env_name:"MASC_KEEPER_ADMISSION_MAX_EVENTS"
      ~exposure:Env_only
      ~value_kind:Integer
      ~default:"32"
      ~reload_class:Next_turn
      ~consumers:
        [ "Env_config_keeper.KeeperAdmissionBounds"
        ; "Keeper_heartbeat_stimulus_intake ready_batch"
        ]
      ~category:"turn"
      "Maximum durable queue selections admitted into one turn; the rest stay pending for a later turn (#29365)"
  ; (* The workspace default for a microVM guest's size. A keeper's own
       [microvm_memory] / [microvm_cpus] wins per dimension. Read at each
       guest start, and a running guest booted with another size is replaced
       at the keeper's next turn rather than adopted. *)
    setting
      ~reload_class:Next_turn
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_sandbox.Runtime.microvm_memory () with
              | Ok memory -> Keeper_microvm_guest_size.memory_argv memory
              | Error detail -> raise (Env_config_core.Config_error detail))))
      ~env_name:"MASC_KEEPER_MICROVM_MEMORY"
      ~exposure:(Toml_and_env "sandbox.microvm_memory")
      ~value_kind:String
      ~default:Env_config_sandbox.Runtime.microvm_memory_default
      ~consumers:
        [ "Keeper_turn_sandbox_runtime microvm boot"
        ; "Keeper_sandbox_control resource_config"
        ]
      ~category:"sandbox"
      "MicroVM guest memory: a whole number followed by m or g"
  ; setting
      ~range:(int_range ~min:1 ())
      ~reload_class:Next_turn
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_sandbox.Runtime.microvm_cpus () with
              | Ok cpus -> display_int (Keeper_microvm_guest_size.cpus_count cpus)
              | Error detail -> raise (Env_config_core.Config_error detail))))
      ~env_name:"MASC_KEEPER_MICROVM_CPUS"
      ~exposure:(Toml_and_env "sandbox.microvm_cpus")
      ~value_kind:Integer
      ~default:(string_of_int Env_config_sandbox.Runtime.microvm_cpus_default)
      ~consumers:
        [ "Keeper_turn_sandbox_runtime microvm boot"
        ; "Keeper_sandbox_control resource_config"
        ]
      ~category:"sandbox"
      "MicroVM guest CPU count"
  ; setting
      ~effective:
        (Reader
           (fun () ->
              (match Env_config_runtime.Tools.searxng_base_url () with
              | Ok url -> url
              | Error detail -> raise (Env_config_core.Config_error detail))))
      ~env_name:"MASC_SEARXNG_URL"
      ~exposure:(Toml_and_env "web_search.searxng_url")
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "SearXNG base URL"
  ; setting
      ~effective:(Reader (fun () -> display_string_option (Env_config_runtime.Tools.web_search_provider_opt ())))
      ~env_name:"MASC_WEB_SEARCH_PROVIDER"
      ~exposure:(Toml_and_env "web_search.provider")
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search provider override"
  ; setting
      ~effective:
        (Reader
           (fun () ->
              display_string_option
                (Env_config_runtime.Tools.web_search_provider_order_opt ())))
      ~env_name:"MASC_WEB_SEARCH_PROVIDER_ORDER"
      ~exposure:(Toml_and_env "web_search.provider_order")
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search provider fallback order"
  ; setting
      ~effective:(Reader (fun () -> display_string_option (Env_config_runtime.Tools.web_search_fallbacks_opt ())))
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
      ~effective:Credential_presence
      ~env_name:"BRAVE_SEARCH_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Brave Search API key (admits the brave and brave_llm_context providers)"
  ; setting
      ~effective:Credential_presence
      ~env_name:"TAVILY_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Tavily API key (admits the tavily provider)"
  ; setting
      ~effective:Credential_presence
      ~env_name:"EXA_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Exa API key (admits the exa provider)"
  ; setting
      ~effective:Credential_presence
      ~env_name:"BING_SEARCH_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Bing Search API key (admits the bing_api provider)"
  ; setting
      ~effective:Credential_presence
      ~env_name:"AZURE_BING_SEARCH_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Azure-issued Bing Search API key (same admission as BING_SEARCH_API_KEY)"
  ; setting
      ~effective:Credential_presence
      ~env_name:"OLLAMA_API_KEY"
      ~exposure:Env_only
      ~value_kind:String
      ~default:"(none)"
      ~consumers:[ "Tool_misc_web_search" ]
      ~category:"web_search"
      "Ollama account API key (admits the ollama provider)"
  ; setting
      ~range:(int_range ~min:1 ~max:60 ())
      ~effective:(Reader (fun () -> display_int (Env_config_runtime.Tools.web_search_timeout_sec ())))
      ~env_name:"MASC_WEB_SEARCH_TIMEOUT_SEC"
      ~exposure:(Toml_and_env "web_search.timeout_sec")
      ~value_kind:Integer
      ~default:"15"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search request timeout in seconds"
  ; setting
      ~range:(float_range ~min:0.0 ())
      ~effective:(Reader (fun () -> display_float (Env_config_runtime.Tools.web_search_cache_ttl_sec ())))
      ~env_name:"MASC_WEB_SEARCH_CACHE_TTL_SEC"
      ~exposure:(Toml_and_env "web_search.cache_ttl_sec")
      ~value_kind:Float
      ~default:"900.0"
      ~consumers:[ "Env_config_runtime.Inference"; "Tool_misc_web_search" ]
      ~category:"web_search"
      "Web-search result cache TTL in seconds"
  ; setting
      ~effective:(Reader (fun () -> display_bool (Env_config_runtime.Otel.enabled ())))
      ~env_name:"MASC_OTEL_ENABLED"
      ~exposure:(Toml_and_env "otel.enabled")
      ~value_kind:Boolean
      ~default:"false"
      ~consumers:[ "Otel_config.enabled"; "Otel_spans" ]
      ~category:"otel"
      "Export OpenTelemetry spans and metrics to the OTLP endpoint"
  ]
;;

let toml_key_opt setting =
  match setting.exposure with
  | Toml_and_env key -> Some key
  | Env_only -> None
;;

let toml_settings = List.filter (fun row -> Option.is_some (toml_key_opt row)) all

let toml_env_mappings =
  List.filter_map
    (fun row -> Option.map (fun key -> key, row.env_name) (toml_key_opt row))
    toml_settings
;;

let find_by_toml_key key =
  List.find_opt
    (fun row ->
       match toml_key_opt row with
       | Some candidate -> String.equal candidate key
       | None -> false)
    all
;;

let effective_value setting =
  match setting.effective with
  | Reader read -> read ()
  | Credential_presence ->
    display_credential_presence (Env_config_core.raw_value_opt setting.env_name)
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
    toml_settings
    |> List.filter (fun row -> row.consumers = [])
    |> List.filter_map (fun row ->
      Option.map
        (Printf.sprintf "TOML setting has no runtime consumer: %s")
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
    ]
;;

let schema_to_yojson () =
  let toml_count = List.length toml_settings in
  let env_only_count = List.length all - toml_count in
  `Assoc
    [ "authority", `String "Keeper_runtime_setting_registry"
    ; "count", `Int (List.length all)
    ; "toml_count", `Int toml_count
    ; "env_only_count", `Int env_only_count
    ; "settings", `List (List.map setting_to_yojson all)
    ]
;;
