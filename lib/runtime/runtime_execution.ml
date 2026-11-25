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

type acp_client =
  { driver : Runtime_acp_client.driver
  ; cli_path : string
  ; args : string list
  ; strip_env : string list
  ; skills_dirs : string list
  ; model : Runtime_acp_client.model_selection
  ; effort : Llm_provider.Reasoning_effort.t option
  ; mode : string option
  ; oauth_source : string option
  ; timeout_s : float
  ; admission_timeout_s : float
  }

type t =
  | Agent_core of Runtime_account_access.api_sealed
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli
  | Claude_code of claude_code
  | Acp of acp_client

let same_account_selection left right =
  match left, right with
  | Claude_code left, Claude_code right ->
    Runtime_account_access.same left.account_home right.account_home
  | Codex_app_server left, Codex_app_server right ->
    Runtime_account_access.same left.account_home right.account_home
  | Acp left, Acp right ->
    Runtime_acp_client.equal_driver left.driver right.driver
    && Option.equal String.equal left.oauth_source right.oauth_source
  | Agent_core _, Agent_core _
  | Antigravity_cli _, Antigravity_cli _ -> true
  | ( Agent_core _
    | Codex_app_server _
    | Antigravity_cli _
    | Claude_code _
    | Acp _ )
    , _ -> false
;;

let is_person_execution = function
  | Claude_code { account_home; _ } -> Runtime_account_access.is_person_sealed account_home
  | Codex_app_server { account_home; _ } -> Runtime_account_access.is_person_sealed account_home
  | Agent_core sealed -> Runtime_account_access.is_person_api sealed
  | Antigravity_cli _ | Acp _ -> false
;;

type checkpoint_owner =
  | Masc_agent_core
  | Official_client

type usage_report =
  | Each_agent_core_response
  | Client_usage_stream

let supports_native_none = function
  | Agent_core _ | Claude_code _ | Acp _ -> true
  | Codex_app_server _ | Antigravity_cli _ -> false

let model_id = function
  | Agent_core config ->
    Some (Runtime_account_access.api_declaration config).Llm_provider.Provider_config.model_id
  | Codex_app_server config -> config.model
  | Antigravity_cli config -> Some config.model
  | Claude_code config -> config.model
  | Acp config ->
    (match config.model with
     | Runtime_acp_client.Keep_cli_default -> None
     | Runtime_acp_client.Explicit_model m -> Some m)
;;

let label = function
  | Agent_core _ -> "agent_core"
  | Codex_app_server _ -> "codex_app_server"
  | Antigravity_cli _ -> "antigravity_cli"
  | Claude_code _ -> "claude_code"
  | Acp config -> "acp_" ^ Runtime_acp_client.driver_to_string config.driver
;;

let checkpoint_owner = function
  | Agent_core _ -> Masc_agent_core
  | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Acp _ ->
    Official_client
;;

let claude_code_inline_result_bytes = 32_768

let tool_result_inline_ceiling_bytes = function
  | Claude_code _ -> claude_code_inline_result_bytes
  | Codex_app_server _ | Antigravity_cli _ | Acp _ ->
      Common.max_tool_result_wire_bytes
  | Agent_core _ -> Common.max_agent_core_inline_result_bytes
;;

let usage_report = function
  | Agent_core _ -> Each_agent_core_response
  | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Acp _ ->
    Client_usage_stream
;;
