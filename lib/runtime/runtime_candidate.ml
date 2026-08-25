(** Runtime_candidate — the provider config a turn dispatches to (RFC-0206).

    Dispatch selects one Runtime, so [type t] is that [Provider_config.t] and
    nothing more. Members delegate to {!Runtime_agent} /
    {!Runtime_provider_binding}. *)

type t = Llm_provider.Provider_config.t

let of_provider_config (cfg : Llm_provider.Provider_config.t) : t = cfg

let provider_cfg (t : t) : Llm_provider.Provider_config.t = t

let selected_endpoint_label (t : t) =
  Runtime_provider_binding.provider_endpoint_label_of_config t
;;

let default_config ~name ~system_prompt ~tools (t : t) =
  Runtime_agent.default_config ~name ~provider_cfg:t ~system_prompt ~tools
