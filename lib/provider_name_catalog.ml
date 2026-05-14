(** MASC-local provider/client literal catalog.

    Keep this private and small: it is an escape hatch for MASC-owned wire
    literals while the legacy Provider_adapter boundary is being shrunk. *)

let cn_claude = "claude"
let cn_kimi = "kimi"
let configured_kimi_api_key_env_hint = "configured " ^ cn_kimi ^ " API key env"
let claude_cli_exit_code_1 = cn_claude ^ " exited with code 1"

let kimi_cli_auth_env_keys = [ "KIMI_API_KEY_SB"; "KIMI_API_KEY" ]
let kimi_cli_runtime_api_key_env = "KIMI_API_KEY"
let kimi_coding_base_url = "https://api.kimi.com/coding/v1"

let env_url_or ~env ~default =
  match Sys.getenv_opt env with
  | Some url ->
    let trimmed = String.trim url in
    if trimmed <> "" then trimmed else default
  | None -> default
;;

let kimi_cli_base_url () =
  env_url_or ~env:"KIMI_BASE_URL" ~default:kimi_coding_base_url
;;

let kimi_cli_config_provider_name = "masc-" ^ cn_kimi
let kimi_cli_config_provider_type = cn_kimi
let kimi_cli_executable = cn_kimi
let kimi_cli_process_name = cn_kimi
let kimi_cli_default_model = "kimi-for-coding"
let kimi_cli_response_id_fallback = cn_kimi ^ "-print"
let kimi_cli_exit_code_prefix = cn_kimi ^ " exited with code "

let kimi_cli_resumable_session_detail =
  "kimi_cli reported a resumable CLI session. Resumable session available via -r."
;;

let headers_with_auth_for_provider_kind
      ~(kind : Llm_provider.Provider_config.provider_kind)
      ~api_key
  =
  let base = [ "Content-Type", "application/json" ] in
  if api_key = ""
  then base
  else (
    match kind with
    | Anthropic | Kimi ->
      ("x-api-key", api_key) :: ("anthropic-version", "2023-06-01") :: base
    | OpenAI_compat | Ollama | Gemini | Glm | Claude_code | DashScope ->
      ("Authorization", "Bearer " ^ api_key) :: base
    | Gemini_cli | Kimi_cli | Codex_cli -> [])
;;

let inference_model_bucket ~provider ~model =
  let has needle =
    String_util.contains_substring_ci provider needle
    || String_util.contains_substring_ci model needle
  in
  if has cn_kimi
  then cn_kimi
  else if has cn_claude || has "anthropic"
  then "anthropic"
  else if has "openai" || has "gpt" || has "codex"
  then "openai"
  else if has "gemini" || has "google"
  then "gemini"
  else if has "glm" || has "zai"
  then "glm"
  else if has "qwen"
  then "qwen"
  else if has "llama"
  then "llama"
  else "other"
;;
