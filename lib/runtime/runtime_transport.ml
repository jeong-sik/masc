(** Runtime_transport — Transport and tool-lane helpers for AGENT_CORE worker exec.

    Keeps provider label resolution and per-call CLI transport construction
    separate from the build/run orchestration in {!Runtime_agent}. *)


(** Resolve a model label string to an AGENT_CORE Provider.config.
    Uses MASC [Runtime_model_string.parse_model_string] with an AGENT_CORE runtime binding.
    Only a defaultless Ollama [auto] may use discovery scoped to its exact endpoint.
    Other unresolved labels are refused rather than silently substituting a model. *)
type label_resolution_error = Runtime_transport_label_resolution.label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string = Runtime_transport_label_resolution.label_resolution_error_to_string
let label_resolution_error_to_core_error = Runtime_transport_label_resolution.label_resolution_error_to_core_error
let resolve_provider_config_of_label = Runtime_transport_label_resolution.resolve_provider_config_of_label

let provider_caps_of_config = Provider_tool_support.agent_core_capabilities_of_config
let provider_supports_inline_tools = Provider_tool_support.provider_supports_inline_tools

(* General display label ([kind:model_id]); used by the tool-lane resolver
   and external consumers. *)
let provider_label (provider_cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf
    "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
    provider_cfg.model_id
;;

(* Provider dispatch is HTTP-only; the [Cli_tool_*] provider kinds defined
   in the pinned agent_core have no registered transport and are
   unreachable here. *)
