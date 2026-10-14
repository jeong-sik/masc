type t =
  | Searxng
  | Brave
  | Brave_llm_context
  | Tavily
  | Exa
  | Bing_api
  | Ollama
  | Zai
[@@deriving enumerate]

let label = function
  | Searxng -> "searxng"
  | Brave -> "brave"
  | Brave_llm_context -> "brave_llm_context"
  | Tavily -> "tavily"
  | Exa -> "exa"
  | Bing_api -> "bing_api"
  | Ollama -> "ollama"
  | Zai -> "zai"
;;

let of_label raw =
  match String.lowercase_ascii (String.trim raw) with
  | "searxng" | "searx" -> Some Searxng
  | "brave" -> Some Brave
  | "brave_llm_context" | "brave-llm-context" -> Some Brave_llm_context
  | "tavily" -> Some Tavily
  | "exa" -> Some Exa
  | "bing" | "bing_api" -> Some Bing_api
  | "ollama" -> Some Ollama
  | "zai" | "z.ai" -> Some Zai
  | "auto" | "" -> None
  | _ -> None
;;

let credential_env_names = function
  | Searxng -> [ "MASC_SEARXNG_URL" ]
  | Brave | Brave_llm_context -> [ "BRAVE_SEARCH_API_KEY" ]
  | Tavily -> [ "TAVILY_API_KEY" ]
  | Exa -> [ "EXA_API_KEY" ]
  | Bing_api -> [ "BING_SEARCH_API_KEY"; "AZURE_BING_SEARCH_API_KEY" ]
  | Ollama -> [ "OLLAMA_API_KEY" ]
  | Zai -> [ "ZAI_API_KEY" ]
;;

let env_value name =
  Env_config_core.raw_value_opt name |> Fun.flip Option.bind String_util.trim_nonempty
;;

let credential provider =
  List.find_map env_value (credential_env_names provider)
;;

let has_credentials provider = Option.is_some (credential provider)

let needs_credential_to_call = function
  | Searxng -> false
  | Brave | Brave_llm_context | Tavily | Exa | Bing_api | Ollama | Zai -> true
;;

let in_default_order = function
  | Brave_llm_context | Zai -> false
  | Searxng | Brave | Tavily | Exa | Bing_api | Ollama -> true
;;

let default_order = List.filter in_default_order all
