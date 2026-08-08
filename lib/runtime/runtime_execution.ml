type codex_app_server =
  { cli_path : string
  ; model : string option
  ; timeout_s : float
  }

type antigravity_cli =
  { cli_path : string
  ; model : string option
  ; timeout_s : float
  }

type t =
  | Agent_core of Llm_provider.Provider_config.t
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli

type checkpoint_owner =
  | Masc_oas
  | Official_client

let agent_core_provider_config = function
  | Agent_core config -> Some config
  | Codex_app_server _ | Antigravity_cli _ -> None
;;

let model_id = function
  | Agent_core config -> Some config.Llm_provider.Provider_config.model_id
  | Codex_app_server config -> config.model
  | Antigravity_cli config -> config.model
;;

let label = function
  | Agent_core _ -> "agent_core"
  | Codex_app_server _ -> "codex_app_server"
  | Antigravity_cli _ -> "antigravity_cli"
;;

let checkpoint_owner = function
  | Agent_core _ -> Masc_oas
  | Codex_app_server _ | Antigravity_cli _ -> Official_client
;;
