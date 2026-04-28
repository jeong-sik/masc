(** Codex_mcp_config_doctor — diagnose the Codex MCP client config.

    Reads [<HOME>/.codex/config.toml] (or whatever
    [MASC_CODEX_CONFIG_PATH] points at) and produces a {!type-t}
    report consumed by [Auth_doctor] and the dashboard. The report
    splits into a flat record of resolved values plus a list of
    {!stage}s with [pass] / [warn] / [fail] / [skip] verdicts.

    Internal parsing helpers ([table_fields_opt], [assoc_opt],
    [assoc_ci_opt], [string_opt], [string_ci_opt], [sorted_keys],
    [accept_header_ok], [server_names_detail], [config_path_opt],
    [analyze_content], [analyze_path], [oauth_login_stage], [empty],
    [stage_to_yojson], [option_field] / [option_bool_field], and the
    expected-value constants [expected_server_name],
    [expected_token_env_var], [expected_x_masc_agent],
    [codex_config_path_env_key]) are hidden — callers consume the
    typed report and the {!analyze_default} / {!to_yojson} /
    {!warnings} / {!next_actions} accessors only. *)

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

val analyze_default : unit -> t
(** Build a report from the resolved Codex config path. When neither
    [HOME] nor [MASC_CODEX_CONFIG_PATH] is set, every dependent stage
    short-circuits to {!Stage_skip}. *)

val to_yojson : t -> Yojson.Safe.t

val warnings : t -> string list
(** Human-readable lines of the form
    [Codex MCP pipeline <stage>: <detail>] for stages whose status
    is {!Stage_fail} or {!Stage_warn}. *)

val next_actions : t -> string list
(** Concrete remediation hints (one per failing/warned stage). *)
