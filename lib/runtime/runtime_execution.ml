type codex_app_server =
  { cli_path : string
  ; account_home : Runtime_official_account.codex Runtime_account_access.sealed
  ; model : string option
  ; timeout_s : float
  }

type antigravity_cli =
  { cli_path : string
  ; model : string
  ; agent : string option
  ; effort : Runtime_antigravity.effort option
  ; oauth_source : string
  ; timeout_s : float
  ; add_dirs : string list
  }

type claude_code =
  { cli_path : string
  ; account_home : Runtime_official_account.claude_code Runtime_account_access.sealed
  ; model : string option
  ; timeout_s : float
  }

type muse_serve =
  { cli_path : string
  ; account_home : Runtime_account_access.muse_home
  ; model : string
  ; timeout_s : float
  }

type vibe_cli =
  { cli_path : string
  ; model : string
  }

type t =
  | Agent_core of Runtime_account_access.api_sealed
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli
  | Claude_code of claude_code
  | Muse_serve of muse_serve
  | Vibe_cli of vibe_cli

let same_account_selection left right =
  match left, right with
  | Claude_code left, Claude_code right ->
    Runtime_account_access.same left.account_home right.account_home
  | Codex_app_server left, Codex_app_server right ->
    Runtime_account_access.same left.account_home right.account_home
  | Agent_core _, Agent_core _
  | Antigravity_cli _, Antigravity_cli _
  | Muse_serve _, Muse_serve _
  | Vibe_cli _, Vibe_cli _ -> true
  | ( Agent_core _
    | Codex_app_server _
    | Antigravity_cli _
    | Claude_code _
    | Muse_serve _
    | Vibe_cli _ )
    , _ -> false
;;

type checkpoint_owner =
  | Masc_agent_core
  | Official_client

type usage_report =
  | Each_agent_core_response
  | Client_usage_stream

let supports_native_none = function
  | Agent_core _ | Claude_code _ -> true
  | Codex_app_server _ | Antigravity_cli _ | Vibe_cli _ -> false
  | Muse_serve _ -> Runtime_native_tools.muse_none_supported

let model_id = function
  | Agent_core config ->
    Some (Runtime_account_access.api_declaration config).Llm_provider.Provider_config.model_id
  | Codex_app_server config -> config.model
  | Antigravity_cli config -> Some config.model
  | Claude_code config -> config.model
  | Muse_serve config -> Some config.model
  | Vibe_cli config -> Some config.model
;;

let label = function
  | Agent_core _ -> "agent_core"
  | Codex_app_server _ -> "codex_app_server"
  | Antigravity_cli _ -> "antigravity_cli"
  | Claude_code _ -> "claude_code"
  | Muse_serve _ -> "muse_serve"
  | Vibe_cli _ -> "vibe_cli"
;;

let checkpoint_owner = function
  | Agent_core _ -> Masc_agent_core
  | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
    Official_client
;;

let vibe_keeper_turn_refused =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "runtime.execution"
       ; detail = "a Mistral Vibe runtime cannot run a Keeper turn"
       })
;;

let claude_code_inline_result_bytes = 32_768

let tool_result_inline_ceiling_bytes = function
  | Claude_code _ -> claude_code_inline_result_bytes
  | Codex_app_server _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
      Common.max_tool_result_wire_bytes
  | Agent_core _ -> Common.max_agent_core_inline_result_bytes
;;

let usage_report = function
  | Agent_core _ -> Each_agent_core_response
  | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
    Client_usage_stream
;;
