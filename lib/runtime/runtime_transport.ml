(** Runtime_transport — Transport and tool-lane helpers for OAS worker exec.

    Keeps provider label resolution and per-call CLI transport construction
    separate from the build/run orchestration in {!Runtime_agent}. *)


(** Resolve a model label string to an OAS Provider.config.
    Uses MASC [Runtime_model_string.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
type label_resolution_error = Runtime_transport_label_resolution.label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string = Runtime_transport_label_resolution.label_resolution_error_to_string
let label_resolution_error_to_sdk_error = Runtime_transport_label_resolution.label_resolution_error_to_sdk_error
let resolve_provider_config_of_label = Runtime_transport_label_resolution.resolve_provider_config_of_label
let invalid_runtime_config = Runtime_transport_label_resolution.invalid_runtime_config

let provider_caps_of_config = Provider_tool_support.oas_capabilities_of_config
let provider_supports_inline_tools = Provider_tool_support.provider_supports_inline_tools

(* provider_label inlined from the removed [Runtime_transport_cli_config].
   General display label ([kind:model_id]); used by the surviving tool-lane
   resolver and external consumers, so it outlives the CLI transport purge. *)
let provider_label (provider_cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf
    "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
    provider_cfg.model_id
;;

(* CLI subprocess transport (json-stream local transport, ctors, argv
   sanitization, MCP-config JSON, and the non-HTTP registry) was removed
   in the CLI provider purge (2026-05-31). Provider dispatch is now
   HTTP-only; the [Cli_tool_*] provider kinds remain defined in agent_sdk but
   have no registered transport and are unreachable here. *)
