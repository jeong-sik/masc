(** Runtime_transport — capability helpers for AGENT_CORE worker execution. *)

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
