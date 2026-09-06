type codex_app_server =
  { cli_path : string
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
  ; model : string option
  ; timeout_s : float
  }

type t =
  | Agent_core of Llm_provider.Provider_config.t
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli
  | Claude_code of claude_code

type checkpoint_owner =
  | Masc_agent_core
  | Official_client

let model_id = function
  | Agent_core config -> Some config.Llm_provider.Provider_config.model_id
  | Codex_app_server config -> config.model
  | Antigravity_cli config -> Some config.model
  | Claude_code config -> config.model
;;

let label = function
  | Agent_core _ -> "agent_core"
  | Codex_app_server _ -> "codex_app_server"
  | Antigravity_cli _ -> "antigravity_cli"
  | Claude_code _ -> "claude_code"
;;

let checkpoint_owner = function
  | Agent_core _ -> Masc_agent_core
  | Codex_app_server _ | Claude_code _ | Antigravity_cli _ -> Official_client
;;
