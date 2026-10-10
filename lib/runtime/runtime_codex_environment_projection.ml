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

let project ~explicit_account ~home ~configured environment =
  environment
  |> Array.to_list
  |> List.filter (fun entry ->
    let name = env_key entry in
    name <> "CODEX_HOME"
    && (not explicit_account
        || not (account_override_environment_key name)
        || List.mem name configured)
    && (child_environment_key_allowed name || List.mem name configured))
  |> fun entries ->
    Option.fold ~none:entries ~some:(fun path -> ("CODEX_HOME=" ^ path) :: entries) home
  |> Array.of_list
;;
