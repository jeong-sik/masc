(** HTTP capacity probe selection for cascade runtime candidates.

    The probe implementation is tied to the native Ollama [/api/ps] schema, so
    the provider-kind check lives next to the probe URL decision instead of in
    the legacy provider adapter boundary. *)

let of_provider_config (cfg : Llm_provider.Provider_config.t) =
  match cfg.kind with
  | Llm_provider.Provider_config.Ollama when not (String.equal cfg.base_url "") ->
    Some cfg.base_url
  | Anthropic | Claude_code | OpenAI_compat | Glm | DashScope | Codex_cli
  | Gemini | Gemini_cli | Kimi | Kimi_cli | Ollama -> None
;;
