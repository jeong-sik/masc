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

val all : t list
(** Every preset once, in declaration order. Derived from {!t}. *)

val of_string : string -> t option
(** The preset whose {!to_string} is exactly [raw]. Any other spelling,
    including a change of case or surrounding whitespace, is [None]. *)

val to_string : t -> string

val labels : string list
(** {!to_string} of every preset in {!all}. *)
