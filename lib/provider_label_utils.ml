(** Return the canonical provider label used for parsed provider kinds. *)
let provider_name_of_kind = function
  | Llm_provider.Provider_config.Anthropic -> "claude"
  | Llm_provider.Provider_config.OpenAI_compat -> "openai"
  | Llm_provider.Provider_config.Gemini -> "gemini"
  | Llm_provider.Provider_config.Glm -> "glm"
  | Llm_provider.Provider_config.Claude_code -> "claude_code"
