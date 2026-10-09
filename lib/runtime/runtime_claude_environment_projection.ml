let tool_search_setting = "ENABLE_TOOL_SEARCH=true"

let inherited_names ~explicit_account =
  let base_names =
    [ "HOME"
    ; "USER"
    ; "PATH"
    ; "TMPDIR"
    ; "XDG_CONFIG_HOME"
    ; "XDG_DATA_HOME"
    ; "XDG_CACHE_HOME"
    ; "SSL_CERT_FILE"
    ; "SSL_CERT_DIR"
    ; "LANG"
    ; "LC_ALL"
    ; "LC_CTYPE"
    ; "TERM"
    ; "NO_COLOR"
    ]
  in
  let inherited_names =
    base_names @
    [ "CLAUDE_CONFIG_DIR"
    ; "ANTHROPIC_API_KEY"; "ANTHROPIC_AUTH_TOKEN"; "ANTHROPIC_BASE_URL"
    ; "ANTHROPIC_CUSTOM_HEADERS"; "ANTHROPIC_MODEL"
    ; "ANTHROPIC_DEFAULT_OPUS_MODEL"; "ANTHROPIC_DEFAULT_SONNET_MODEL"
    ; "ANTHROPIC_DEFAULT_HAIKU_MODEL"; "ANTHROPIC_SMALL_FAST_MODEL"
    ; "CLAUDE_CODE_OAUTH_TOKEN"
    ; "CLAUDE_CODE_USE_BEDROCK"; "CLAUDE_CODE_USE_VERTEX"
    ; "CLAUDE_CODE_USE_FOUNDRY"; "CLAUDE_CODE_USE_MANTLE"
    ; "ANTHROPIC_BEDROCK_BASE_URL"; "ANTHROPIC_VERTEX_BASE_URL"
    ; "ANTHROPIC_VERTEX_PROJECT_ID"; "CLOUD_ML_REGION"
    ; "CLAUDE_CODE_SKIP_BEDROCK_AUTH"; "CLAUDE_CODE_SKIP_VERTEX_AUTH"
    ; "CLAUDE_CODE_SKIP_FOUNDRY_AUTH"
    ; "AWS_ACCESS_KEY_ID"; "AWS_SECRET_ACCESS_KEY"; "AWS_SESSION_TOKEN"
    ; "AWS_REGION"; "AWS_DEFAULT_REGION"; "AWS_PROFILE"
    ; "AWS_CONFIG_FILE"; "AWS_SHARED_CREDENTIALS_FILE"; "AWS_BEARER_TOKEN_BEDROCK"
    ; "GOOGLE_APPLICATION_CREDENTIALS"; "GOOGLE_CLOUD_PROJECT"
    ; "ANTHROPIC_FOUNDRY_API_KEY"; "ANTHROPIC_FOUNDRY_RESOURCE"
    ; "ANTHROPIC_FOUNDRY_BASE_URL"; "AZURE_TENANT_ID"; "AZURE_CLIENT_ID"; "AZURE_CLIENT_SECRET"
    ]
  in
  inherited_names
  |> List.filter (fun name ->
    not explicit_account || List.mem name base_names)

;;

let of_inherited ~account_home inherited =
  (* Claude Code loads the auto-memory index kept for its working directory
     (~/.claude/projects/<cwd>/memory/MEMORY.md) into every session. A Keeper
     runs with the operator's base path as its working directory, so without
     this it read the operator's own memory index -- notes from unrelated
     work and personal details -- on every session. --setting-sources ""
     does not cover this; the environment switch does (measured with Claude
     Code 2.1.282: the `instructions` attachment carrying MEMORY.md is gone). *)
  ("CLAUDE_CODE_ENTRYPOINT=masc"
   :: "CLAUDE_AGENT_SDK_VERSION=masc-ocaml"
   :: "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
   :: tool_search_setting
   :: (match account_home with None -> inherited
       | Some home -> ("CLAUDE_CONFIG_DIR=" ^ home) :: inherited))
  |> Array.of_list
;;
