(** OAS type adapters — thin wrappers around OAS Provider conversion.

    @since 2.130.0
    @since 2.136.0 — Fully delegates to OAS Provider.config_of_provider_config
                      (env var fallback moved to OAS v0.87.0). *)

(** Convert OAS Provider_config.t to OAS Provider.config for Agent Builder.
    Delegates entirely to {!Agent_sdk.Provider.config_of_provider_config}
    which handles provider dispatch and env var fallback. *)
let provider_config_to_oas (cfg : Llm_provider.Provider_config.t)
    : Agent_sdk.Provider.config =
  Agent_sdk.Provider.config_of_provider_config cfg

(** Convert a model label string (e.g. "llama:qwen3.5") to an OAS Provider.config.
    Parses via OAS Cascade_config.parse_model_string which uses
    Provider_registry as SSOT. Returns None only if parsing fails. *)
let to_oas_provider_of_label (label : string) : Agent_sdk.Provider.config option =
  match Llm_provider.Cascade_config.parse_model_string label with
  | None -> None
  | Some pc -> Some (provider_config_to_oas pc)

(** Filter System-role messages (not passed to OAS completion API). *)
let to_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message option =
  match m.role with System -> None | _ -> Some m

let of_oas_message (m : Agent_sdk.Types.message) : Agent_sdk.Types.message = m
