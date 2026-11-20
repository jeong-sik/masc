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
[@@deriving enumerate]

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
;;

let of_string raw = List.find_opt (fun preset -> String.equal raw (to_string preset)) all
let labels = List.map to_string all
