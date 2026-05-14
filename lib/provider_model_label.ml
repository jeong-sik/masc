let normalize_label label = String.trim label |> String.lowercase_ascii

let display_provider_name label =
  match normalize_label label with
  | "glm" | "glm-api" -> "glm"
  | "glm-coding" | "glm-coding-plan" -> "glm-coding"
  | "kimi-api" -> "kimi"
  | "kimi-coding" | "kimi_coding" -> "kimi-coding"
  | _ -> String.trim label
;;

let of_parts provider model = Printf.sprintf "%s:%s" provider model
let prefix provider = of_parts provider ""

let of_config (cfg : Llm_provider.Provider_config.t) =
  let provider =
    Llm_provider.Provider_registry.provider_name_of_config cfg |> display_provider_name
  in
  of_parts provider cfg.model_id
;;
