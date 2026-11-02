type t =
  | Anthropic
  | Kimi
  | Openai_chat
  | Ollama
  | Gemini
  | Glm
  | Openai_chat_extended
  | Openrouter
  | Cohere
  | Mimo
  | Ollama_cloud
  | Ollama_cloud_v1
  | Nvidia

let spellings =
  [ "anthropic", Anthropic
  ; "kimi", Kimi
  ; "openai_compat", Openai_chat
  ; "ollama", Ollama
  ; "gemini", Gemini
  ; "glm", Glm
  ; "claude", Anthropic
  ; "openai", Openai_chat
  ; "openai_chat", Openai_chat
  ; "zhipu", Glm
  ; "glm-coding", Glm
  ; "openai_compat_chat_extended", Openai_chat_extended
  ; "openai_chat_extended", Openai_chat_extended
  ; "openrouter", Openrouter
  ; "xai", Openai_chat_extended
  ; "mistral", Openai_chat_extended
  ; "cohere", Cohere
  ; "mimo", Mimo
  ; "ollama_cloud", Ollama_cloud
  ; "ollama_cloud_v1", Ollama_cloud_v1
  ; "nvidia", Nvidia
  ]

let labels = List.map fst spellings
let of_string raw = List.assoc_opt (String.trim raw |> String.lowercase_ascii) spellings

let to_string = function
  | Anthropic -> "anthropic"
  | Kimi -> "kimi"
  | Openai_chat -> "openai_chat"
  | Ollama -> "ollama"
  | Gemini -> "gemini"
  | Glm -> "glm"
  | Openai_chat_extended -> "openai_chat_extended"
  | Openrouter -> "openrouter"
  | Cohere -> "cohere"
  | Mimo -> "mimo"
  | Ollama_cloud -> "ollama_cloud"
  | Ollama_cloud_v1 -> "ollama_cloud_v1"
  | Nvidia -> "nvidia"
