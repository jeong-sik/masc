(** Cascade configuration: named provider profiles with JSON hot-reload
    and discovery-aware health filtering.

    Provider defaults are sourced from {!Provider_registry} (SSOT).

    @since 0.59.0
    @since 0.92.0 decomposed into Cascade_model_resolve, Cascade_throttle,
    Cascade_config_loader
    @since RFC-0056 PR D3 facade re-exports
      {!Cascade_config_provider_binding},
      {!Cascade_config_parser},
      {!Cascade_config_selection},
      {!Cascade_config_resolve},
      {!Cascade_config_provider_filter},
      {!Cascade_config_strategy_resolve}.
      Behaviour is byte-equivalent to the pre-split godfile. *)

(* ── Re-exports from extracted modules ─────────────── *)

(* Model resolution (existing sub-module) *)
let resolve_auto_model_id = Cascade_model_resolve.resolve_auto_model_id

(* Config loader (existing sub-module) *)
let load_catalog_source = Cascade_config_loader.load_catalog_source

type inference_params = Cascade_config_loader.inference_params = {
  temperature: float option;
  max_tokens: int option;
  keep_alive: string option;
  num_ctx: int option;
  thinking_enabled: bool option;
  thinking_budget: int option;
}

let resolve_inference_params = Cascade_config_loader.resolve_inference_params
let resolve_api_key_env = Cascade_config_loader.resolve_api_key_env

(* Provider binding helpers (this PR) *)
let headers_with_auth = Cascade_config_provider_binding.headers_with_auth
let normalize_openai_compat_request_path =
  Cascade_config_provider_binding.normalize_openai_compat_request_path

(* Parsing + provider config construction (this PR) *)
type weighted_entry_drop = Cascade_config_parser.weighted_entry_drop =
  | Drop_unregistered_scheme of { model : string; scheme : string }
  | Drop_unavailable_scheme of { model : string; scheme : string }
  | Drop_invalid_syntax of string

let parse_model_string = Cascade_config_parser.parse_model_string
let parse_weighted_entry_diag = Cascade_config_parser.parse_weighted_entry_diag
let parse_weighted_entry_with_drop_metric =
  Cascade_config_parser.parse_weighted_entry_with_drop_metric
let parse_weighted_entries = Cascade_config_parser.parse_weighted_entries
let parse_model_string_result = Cascade_config_parser.parse_model_string_result
let expand_auto_models = Cascade_config_parser.expand_auto_models
let expand_weighted_auto_entries =
  Cascade_config_parser.expand_weighted_auto_entries
let resolve_provider_model_max_context =
  Cascade_config_parser.resolve_provider_model_max_context

(* Selection / weighted ordering (this PR) *)
let order_weighted_entries = Cascade_config_selection.order_weighted_entries

type candidate_info = Cascade_config_selection.candidate_info = {
  model_string : string;
  display_model_string : string;
  provider_name : string option;
  display_provider_name : string option;
  runtime_kind : string option;
  expanded_models : string list;
  config_weight : int;
  effective_weight : int;
  success_rate : float;
  in_cooldown : bool;
}

(* Resolve (cascade_source + selection_trace + materialized json) — this PR *)
type cascade_source = Cascade_config_resolve.cascade_source =
  | Named
  | Default_fallback
  | Hardcoded_defaults
  | Load_failed of string

type selection_trace = Cascade_config_resolve.selection_trace = {
  candidates : candidate_info list;
  source : cascade_source;
}

let selection_trace_of_weighted_entries =
  Cascade_config_resolve.selection_trace_of_weighted_entries
let resolve_model_strings = Cascade_config_resolve.resolve_model_strings
let resolve_model_strings_traced =
  Cascade_config_resolve.resolve_model_strings_traced
let resolve_model_strings_with_trace =
  Cascade_config_resolve.resolve_model_strings_with_trace
let expand_model_strings_for_execution =
  Cascade_config_resolve.expand_model_strings_for_execution

(* Health filtering (existing sub-module) *)
let filter_healthy_strict = Cascade_health_filter.filter_healthy_strict
let health_filter_rejection_to_string =
  Cascade_health_filter.health_filter_rejection_to_string

type health_filter_rejection = Cascade_health_filter.health_filter_rejection =
  | All_missing_api_key of int
  | All_local_unhealthy of { local_count : int; cloud_count : int }

(* Provider/capability filter + context window helpers (this PR) *)
let effective_max_context = Cascade_config_provider_filter.effective_max_context
let resolve_label_context = Cascade_config_provider_filter.resolve_label_context
let filter_by_capabilities = Cascade_config_provider_filter.filter_by_capabilities
let text_of_response = Cascade_config_provider_filter.text_of_response

type provider_filter_rejection =
  Cascade_config_provider_filter.provider_filter_rejection =
  | Filter_matched_none of { filter : string list; available_kinds : string list }

let provider_filter_rejection_to_string =
  Cascade_config_provider_filter.provider_filter_rejection_to_string
let apply_provider_filter = Cascade_config_provider_filter.apply_provider_filter
let apply_provider_filter_strict =
  Cascade_config_provider_filter.apply_provider_filter_strict

(* Strategy / priority-tier / concurrency resolution (this PR) *)
let normalize_priority_tiers =
  Cascade_config_strategy_resolve.normalize_priority_tiers
let resolve_strategy = Cascade_config_strategy_resolve.resolve_strategy
let resolve_ollama_max_concurrent =
  Cascade_config_strategy_resolve.resolve_ollama_max_concurrent
let resolve_cli_max_concurrent =
  Cascade_config_strategy_resolve.resolve_cli_max_concurrent
