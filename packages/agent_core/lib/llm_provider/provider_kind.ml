(** Provider kind sum type, split from [Provider_config] so it can be shared
    by {!Types.inference_telemetry} without introducing a
    [Provider_config <-> Types] dependency cycle.

    [Provider_config] re-exports this type and its helpers so existing
    callers that refer to [Llm_provider.Provider_config.Anthropic] /
    [Provider_config.string_of_provider_kind] keep working unchanged.

    @since 0.165.0 *)

type t =
  | Anthropic
  | Kimi
  | OpenAI_compat
  | Ollama
  | Gemini
  | Glm
  | DashScope

let to_string = function
  | Anthropic -> "anthropic"
  | Kimi -> "kimi"
  | OpenAI_compat -> "openai_compat"
  | Ollama -> "ollama"
  | Gemini -> "gemini"
  | Glm -> "glm"
  | DashScope -> "dashscope"
;;

let all : t list = [ Anthropic; Kimi; OpenAI_compat; Ollama; Gemini; Glm; DashScope ]

let default_api_key_env = function
  | Anthropic -> Some "ANTHROPIC_API_KEY"
  | Kimi -> Some "KIMI_API_KEY"
  | Gemini -> Some "GEMINI_API_KEY"
  | Glm -> Some "ZAI_API_KEY"
  | DashScope -> Some "DASHSCOPE_API_KEY"
  | OpenAI_compat | Ollama ->
    (* Named providers sharing these wire kinds declare their own exact
       credential environment in the provider catalog. *)
    None
;;

let of_canonical_string raw =
  List.find_opt (fun kind -> String.equal raw (to_string kind)) all
;;

let of_string raw = raw |> String.trim |> String.lowercase_ascii |> of_canonical_string
let pp fmt k = Format.pp_print_string fmt (to_string k)
let show = to_string
let to_yojson (k : t) : Yojson.Safe.t = `String (to_string k)

let of_yojson (json : Yojson.Safe.t) : t Ppx_deriving_yojson_runtime.error_or =
  match json with
  | `String s ->
    (match of_string s with
     | Some k -> Ok k
     | None -> Error (Printf.sprintf "provider_kind: unknown value %S" s))
  | _ -> Error "provider_kind: expected JSON string"
;;
