(** Runtime_candidate — single-dispatch execution candidate (RFC-0206).

    Runtime dispatch
    wrapped a [Provider_config.t] with health / capacity / probe keys to feed
    the multi-candidate selection FSM. With single-binding dispatch there is
    exactly one Runtime, so the candidate collapses to its provider config and
    the health/capacity/strategy/selection machinery is dropped.

    [type t] is the selected [Provider_config.t]. The surviving members
    delegate to {!Runtime_agent} / {!Runtime_provider_binding}; error
    decoration is collapsed to identity. *)

type t = Llm_provider.Provider_config.t

let of_provider_config (cfg : Llm_provider.Provider_config.t) : t = cfg

let of_provider_configs (cfgs : Llm_provider.Provider_config.t list) : t list = cfgs

let provider_cfg (t : t) : Llm_provider.Provider_config.t = t

(* Provider-scoped health key retained for provider_attempt's single-provider
   health recording. No multi-candidate selection consumes these. *)
let model_health_key (t : t) = Runtime_provider_binding.provider_health_key_of_config t

let default_config ~name ~system_prompt ~tools (t : t) =
  Runtime_agent.default_config ~name ~provider_cfg:t ~system_prompt ~tools
