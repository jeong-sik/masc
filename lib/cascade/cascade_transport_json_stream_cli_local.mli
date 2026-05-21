(** JSON-stream CLI completion transport. *)

type config =
  { cli_path : string
  ; process_name : string
  ; model : string option
  ; cwd : string option
  ; config_json : string option
  ; mcp_config_json : string list
  ; extra_env : (string * string) list
  ; cancel : unit Eio.Promise.t option
  ; stdout_idle_timeout_s : float option
  }

val default_config : config

val build_args
  :  config:config
  -> req_config:Llm_provider.Provider_config.t
  -> mcp_config_json:string list
  -> prompt:string
  -> string list

val should_log_stderr_line : string -> bool
val resumable_session_detail : string
val text_looks_like_resumable_session : string -> bool
val resumable_session_detail_of_text : string -> string
val resumable_session_exit_code_of_text : string -> int option

val classify_cli_error
  :  ('a, Llm_provider.Http_client.http_error) result
  -> ('a, Llm_provider.Http_client.http_error) result

val create
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> config:config
  -> Llm_provider.Llm_transport.t
