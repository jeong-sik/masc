(** Provider identity helpers.

    @stability Internal *)

module Runtime_binding = Agent_core.Provider_runtime_binding

let default_headers_for_kind (kind : Llm_provider.Provider_config.provider_kind) =
  let base = [ ("Content-Type", "application/json") ] in
  match kind with
  | Anthropic | Kimi ->
    ("anthropic-version", Llm_provider.Api_common.api_version) :: base
  | OpenAI_compat | Ollama | Gemini | Glm -> base
;;
