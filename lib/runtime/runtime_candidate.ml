(** Runtime_candidate — the provider config a turn dispatches to (RFC-0206).

    Dispatch selects one Runtime, so [type t] is that [Provider_config.t] and
    nothing more. Members delegate to {!Runtime_agent}. *)

type t = Llm_provider.Provider_config.t

let of_provider_config (cfg : Llm_provider.Provider_config.t) : t = cfg

let provider_cfg (t : t) : Llm_provider.Provider_config.t = t

let default_config ~media_store ~name ~system_prompt ~tools (t : t) =
  Runtime_agent.default_config ~media_store ~name ~provider_cfg:t ~system_prompt ~tools
