(** Chain engine and model selection environment configuration.

    Centralizes MASC_CHAIN_*, MASC_DEFAULT_*, LLAMA_SWARM_MODEL,
    and related inference routing env vars. *)

open Env_config_core

(** {1 Chain Engine Limits} *)

module Limits = struct
  let max_nodes =
    get_int ~default:100 "MASC_CHAIN_MAX_NODES"

  let max_depth =
    get_int ~default:10 "MASC_CHAIN_MAX_DEPTH"

  let max_fanout =
    get_int ~default:5 "MASC_CHAIN_MAX_FANOUT"

  let max_concurrency =
    get_int ~default:4 "MASC_CHAIN_MAX_CONCURRENCY"
end

(** {1 Chain Paths} *)

module Paths = struct
  let source_base_path_opt () =
    Sys.getenv_opt "MASC_CHAIN_SOURCE_BASE_PATH" |> trim_opt

  let checkpoint_dir_opt () =
    Sys.getenv_opt "MASC_CHAIN_CHECKPOINT_DIR" |> trim_opt

  let history_file_opt () =
    match Sys.getenv_opt "MASC_CHAIN_HISTORY_FILE" |> trim_opt with
    | Some _ as v -> v
    | None -> Sys.getenv_opt "CHAIN_HISTORY_FILE" |> trim_opt

  let run_store_path_opt () =
    Sys.getenv_opt "MASC_CHAIN_RUN_STORE_PATH" |> trim_opt
end

(** {1 Chain Logging} *)

module Log = struct
  let level =
    get_string ~default:"info" "MASC_CHAIN_LOG_LEVEL"

  let format =
    get_string ~default:"text" "MASC_CHAIN_LOG_FORMAT"

  let run_log_enabled =
    get_bool ~default:false "MASC_CHAIN_RUN_LOG"

  let run_log_path_opt () =
    Sys.getenv_opt "MASC_CHAIN_RUN_LOG_PATH" |> trim_opt

  let run_log_stream =
    get_bool ~default:false "MASC_CHAIN_RUN_LOG_STREAM"
end

(** {1 Model Selection & Cascade} *)

module Model = struct
  let default_cascade_opt () =
    Sys.getenv_opt "MASC_DEFAULT_CASCADE" |> trim_opt

  let routing_cascade_opt () =
    Sys.getenv_opt "MASC_ROUTING_CASCADE" |> trim_opt

  let default_provider_opt () =
    Sys.getenv_opt "MASC_DEFAULT_PROVIDER" |> trim_opt

  let default_model_opt () =
    Sys.getenv_opt "MASC_DEFAULT_MODEL" |> trim_opt

  let orchestrator_model_opt () =
    Sys.getenv_opt "MASC_CHAIN_ORCHESTRATOR_MODEL" |> trim_opt

  let llama_swarm_model_opt () =
    Sys.getenv_opt "LLAMA_SWARM_MODEL" |> trim_opt

  let goal_models_opt () =
    Sys.getenv_opt "MASC_GOAL_MODELS" |> trim_opt

  let goal_dispatch_runtime =
    get_string ~default:"local" "MASC_GOAL_DISPATCH_RUNTIME"
end

(** {1 Local LLM (Llama)} *)

module Llama = struct
  let runtime_debug =
    get_bool ~default:false "MASC_LLAMA_RUNTIME_DEBUG"

  let runtime_cooldown_sec =
    get_float ~default:30.0 "MASC_LLAMA_RUNTIME_COOLDOWN_SEC"

  let swarm_live_script_opt () =
    Sys.getenv_opt "MASC_SWARM_LIVE_SCRIPT" |> trim_opt
end

(** {1 Mitosis Thresholds} *)

module Mitosis = struct
  let prepare_threshold_opt () =
    Sys.getenv_opt "MASC_MITOSIS_PREPARE_THRESHOLD" |> trim_opt

  let handoff_threshold_opt () =
    Sys.getenv_opt "MASC_MITOSIS_HANDOFF_THRESHOLD" |> trim_opt
end

(** {1 Procedural Memory} *)

module Procedural = struct
  let min_evidence =
    get_int ~default:2 "MASC_PROC_MIN_EVIDENCE"

  let min_confidence =
    get_float ~default:0.7 "MASC_PROC_MIN_CONFIDENCE"
end

(** {1 Memory OAS Bridge} *)

module Memory = struct
  let oas_default_importance =
    get_float ~default:0.5 "MASC_MEMORY_OAS_DEFAULT_IMPORTANCE"
end
