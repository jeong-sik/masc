(** Closed provider capability presets, independent of wire identity, model
    lookup and publication. Spellings are decoded only at catalog boundaries. *)
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

val of_string : string -> t option
val to_string : t -> string
val labels : string list
(** All accepted spellings, including aliases. Unknown labels remain absent. *)
