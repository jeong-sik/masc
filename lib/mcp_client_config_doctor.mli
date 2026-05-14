(** Mcp_client_config_doctor — diagnose an external MCP client config.

    The expected server name, bearer-token env var, X-MASC-Agent value,
    and config path are supplied by [Local_mcp_client_catalog], which is
    loaded from [cascade.toml]. *)

type stage_status =
  | Stage_pass
  | Stage_warn
  | Stage_fail
  | Stage_skip

type stage = {
  name : string;
  status : stage_status;
  detail : string;
}

type t = {
  config_path : string option;
  file_present : bool;
  parse_error : string option;
  server_names : string list;
  server_present : bool;
  url : string option;
  bearer_token_env_var : string option;
  bearer_token_env_matches : bool option;
  authorization_header_present : bool option;
  accept_header : string option;
  accept_header_ok : bool option;
  x_masc_agent : string option;
  x_masc_agent_ok : bool option;
  stages : stage list;
}

val stage_status_to_string : stage_status -> string

val analyze_default :
  spec:Local_mcp_client_catalog.spec ->
  config_sync:Local_mcp_client_catalog.config_sync ->
  unit ->
  t
(** Build a report from the resolved MCP client config path. When neither
    [HOME] nor the configured path env var is set, every dependent stage
    short-circuits to {!Stage_skip}. *)

val to_yojson : t -> Yojson.Safe.t

val warnings : t -> string list
(** Human-readable lines of the form
    [MCP client config pipeline <stage>: <detail>] for stages whose status
    is {!Stage_fail} or {!Stage_warn}. *)

val next_actions :
  spec:Local_mcp_client_catalog.spec ->
  config_sync:Local_mcp_client_catalog.config_sync ->
  t ->
  string list
(** Concrete remediation hints (one per failing/warned stage). *)
