type spec =
  { client_name : string
  ; agent_name : string
  ; token_env_var : string
  }

let codex_server_name = "masc"
let codex_client_name = "codex"
let codex_agent_name = "codex-mcp-client"
let codex_token_env_var = "MASC_MCP_TOKEN"
let codex_login_supported = false

let codex_login_note =
  "`codex mcp login` is OAuth-only; masc-mcp uses bearer token auth."
;;

let claude_client_name = "claude"
let claude_agent_name = "claude"
let claude_token_env_var = "MASC_CLAUDE_MCP_TOKEN"
let gemini_client_name = "gemini"
let gemini_agent_name = "gemini"
let gemini_token_env_var = "MASC_GEMINI_MCP_TOKEN"
let dashboard_dev_agent_name = "dashboard-dev"
let admin_agent_name = "admin"

let specs =
  [ { client_name = codex_client_name
    ; agent_name = codex_agent_name
    ; token_env_var = codex_token_env_var
    }
  ; { client_name = claude_client_name
    ; agent_name = claude_agent_name
    ; token_env_var = claude_token_env_var
    }
  ; { client_name = gemini_client_name
    ; agent_name = gemini_agent_name
    ; token_env_var = gemini_token_env_var
    }
  ]
;;

let generated_config_server_name = codex_server_name

let generated_config_client =
  { client_name = codex_client_name
  ; agent_name = codex_agent_name
  ; token_env_var = codex_token_env_var
  }
;;

let generated_config_sync_env_key = "MASC_SYNC_CODEX_MCP_CONFIG"
let generated_config_path_env_key = "MASC_CODEX_CONFIG_PATH"
let generated_config_relative_path = Filename.concat ".codex" "config.toml"
let generated_config_login_supported = codex_login_supported
let generated_config_login_note = codex_login_note

let spec_matches_agent agent_name spec =
  String.equal spec.agent_name agent_name || String.equal spec.client_name agent_name
;;

let token_env_var_for_agent agent_name =
  match List.find_opt (spec_matches_agent agent_name) specs with
  | Some spec -> spec.token_env_var
  | None -> codex_token_env_var
;;

let is_agent_name agent_name = List.exists (spec_matches_agent agent_name) specs

let worker_agent_credentials =
  List.map (fun spec -> spec.agent_name, Masc_domain.Worker) specs
;;

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
       if value = "" || Hashtbl.mem seen value
       then false
       else (
         Hashtbl.replace seen value ();
         true))
    values
;;

let watched_agent_names ~initial_admin ~admin_token_env_agent =
  [ Some codex_client_name
  ; Some codex_agent_name
  ; Some dashboard_dev_agent_name
  ; Some admin_agent_name
  ; initial_admin
  ; admin_token_env_agent
  ]
  |> List.filter_map Fun.id
  |> dedupe_keep_order
;;
