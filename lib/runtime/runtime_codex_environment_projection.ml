let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

let child_environment_key_allowed = function
  | "HOME"
  | "PATH"
  | "TMPDIR"
  | "CODEX_HOME"
  | "XDG_CONFIG_HOME"
  | "XDG_DATA_HOME"
  | "XDG_CACHE_HOME"
  | "SSL_CERT_FILE"
  | "SSL_CERT_DIR"
  | "LANG"
  | "LC_ALL"
  | "LC_CTYPE"
  | "TERM"
  | "NO_COLOR"
  | "OPENAI_API_KEY" | "OPENAI_BASE_URL" | "CODEX_API_KEY" | "CODEX_ACCESS_TOKEN"
  | "AWS_ACCESS_KEY_ID" | "AWS_SECRET_ACCESS_KEY" | "AWS_SESSION_TOKEN"
  | "AWS_REGION" | "AWS_DEFAULT_REGION" | "AWS_PROFILE"
  | "AWS_CONFIG_FILE" | "AWS_SHARED_CREDENTIALS_FILE" | "AWS_BEARER_TOKEN_BEDROCK" -> true
  | _ -> false
;;

let account_override_environment_key = function
  | "OPENAI_API_KEY" | "OPENAI_BASE_URL" | "CODEX_API_KEY" | "CODEX_ACCESS_TOKEN"
  | "AWS_ACCESS_KEY_ID" | "AWS_SECRET_ACCESS_KEY" | "AWS_SESSION_TOKEN"
  | "AWS_REGION" | "AWS_DEFAULT_REGION" | "AWS_PROFILE"
  | "AWS_CONFIG_FILE" | "AWS_SHARED_CREDENTIALS_FILE" | "AWS_BEARER_TOKEN_BEDROCK" ->
    true
  | _ -> false
;;

(* Strict denylist enforced even when a shared/untrusted [CODEX_HOME/config.toml]
   declares the variable in [model_providers.*.env_key] or [env_http_headers].
   Prevents a tampered Codex config from exfiltrating MASC server credentials,
   GitHub/Slack/Discord tokens, unrelated provider API keys, or dynamic-linker
   / shell injection variables into the Codex child process. *)
let is_denied_environment_key name =
  let upper = String.uppercase_ascii (String.trim name) in
  String.starts_with ~prefix:"MASC_" upper
  || String.starts_with ~prefix:"LD_" upper
  || String.starts_with ~prefix:"DYLD_" upper
  || String.starts_with ~prefix:"SLACK_" upper
  || String.starts_with ~prefix:"DISCORD_" upper
  || String.starts_with ~prefix:"ANTHROPIC_" upper
  || String.starts_with ~prefix:"CLAUDE_" upper
  || String.starts_with ~prefix:"GEMINI_" upper
  || String.starts_with ~prefix:"GOOGLE_" upper
  || String.starts_with ~prefix:"VERTEX_" upper
  || String.starts_with ~prefix:"ZAI_" upper
  || String.starts_with ~prefix:"GLM_" upper
  || String.starts_with ~prefix:"KIMI_" upper
  || String.starts_with ~prefix:"MOONSHOT_" upper
  || String.starts_with ~prefix:"OPENROUTER_" upper
  || String.starts_with ~prefix:"ELEVENLABS_" upper
  || String.starts_with ~prefix:"MISTRAL_" upper
  || String.starts_with ~prefix:"OLLAMA_" upper
  || String.starts_with ~prefix:"BASH_FUNC_" upper
  ||
  match upper with
  | "GH_TOKEN"
  | "GITHUB_TOKEN"
  | "GH_ENTERPRISE_TOKEN"
  | "GITHUB_PAT"
  | "NPM_TOKEN"
  | "PYPI_TOKEN"
  | "OPAM_TOKEN"
  | "SSH_AUTH_SOCK"
  | "SSH_AGENT_PID"
  | "BASH_ENV"
  | "ENV"
  | "ZDOTDIR"
  | "PYTHONSTARTUP"
  | "NODE_OPTIONS"
  | "PERL5OPT"
  | "RUBYOPT"
  | "GCONV_PATH"
  | "IFS" -> true
  | _ -> false
;;

let project ~explicit_account ~home ~configured environment =
  let configured = List.filter (fun name -> not (is_denied_environment_key name)) configured in
  environment
  |> Array.to_list
  |> List.filter (fun entry ->
    let name = env_key entry in
    name <> "CODEX_HOME"
    && not (is_denied_environment_key name)
    && (not explicit_account
        || not (account_override_environment_key name)
        || List.mem name configured)
    && (child_environment_key_allowed name || List.mem name configured))
  |> fun entries ->
    Option.fold ~none:entries ~some:(fun path -> ("CODEX_HOME=" ^ path) :: entries) home
  |> Array.of_list
;;
