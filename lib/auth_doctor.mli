(** Auth_doctor — Server-side authentication health diagnostic.

    Inspects the resolved auth directory + MCP client wiring +
    admin-token sources and produces a structured {!t} report
    that is rendered as JSON ({!to_yojson}) or human text
    ({!render_text}) and graded by {!exit_code} for CLI use.

    Internal: ~16 helpers + 1 type stay private —
    \[admin_token_env_state] enum, [codex_mcp_token_env_var] /
    [codex_mcp_login_note] pinned literals,
    [canonicalize_path] / [file_exists] / [read_nonempty_text_file]
    file-system helpers, [dedupe_keep_order], [option_field],
    [raw_token_file_path], [watched_agent_of_credential],
    [watched_agent_names], [admin_token_env_state],
    [admin_token_env_fields], [role_counts_of_credentials],
    [live_admin_token_file_source], [admin_bearer_sources],
    [codex_mcp_report], MCP client identity checks, plus the per-record yojson encoders
    ([watched_agent_to_yojson], [codex_mcp_to_yojson]).
    All consumed only inside {!analyze} / {!to_yojson} /
    {!render_text}. *)

(** {1 Status grade} *)

type status =
  | Ok
  | Warn
  | Error

val status_to_string : status -> string
(** [status_to_string s] returns the canonical lowercase label:
    ["ok"] / ["warn"] / ["error"].  Pinned literal — drift would
    break tooling that parses the auth-doctor JSON. *)

(** {1 Per-agent + MCP records} *)

type watched_agent = {
  agent_name : string;
  credential_present : bool;
  credential_role : string option;
  can_admin : bool option;
  expires_at : string option;
  raw_token_file_present : bool;
}
(** Per-agent credential snapshot.  Aggregated under
    {!t.watched_agents}. *)

type codex_mcp = {
  server_name : string;
  auth_model : string;
  token_env_var : string;
  token_env_configured : bool;
  token_status : string;
  token_agent : string option;
  token_role : string option;
  token_can_read_state : bool option;
  login_supported : bool;
  login_note : string;
  config : Codex_mcp_config_doctor.t;
}
(** Codex MCP wiring snapshot.  [login_note] documents that
    [codex mcp login] is OAuth-only while masc-mcp uses bearer
    token auth — pinned at the contract seam. *)

type mcp_client = {
  client_name : string;
  agent_name : string;
  token_env_var : string;
  token_file_path : string;
  credential_present : bool;
  credential_role : string option;
  raw_token_file_present : bool;
  token_source : string;
  token_status : string;
  token_agent : string option;
  token_role : string option;
  token_can_read_state : bool option;
  identity_ready : bool;
}
(** Per-client MCP identity readiness for local Codex/Claude/Gemini
    bearer-token wiring.  [token_source] is ["env"], ["token_file"],
    or ["missing"]; [token_status] is ["live"], ["wrong_agent"],
    ["invalid_or_expired"], or ["missing"]. *)

(** {1 Aggregate report} *)

type t = {
  status : status;
  base_path : string;
  auth_dir : string;
  auth_config_path : string;
  auth_enabled : bool;
  require_token : bool;
  default_role : string;
  initial_admin : string option;
  bind_host : string;
  bind_is_loopback : bool;
  http_auth_strict : bool;
  dashboard_dev_token_available : bool;
  dashboard_dev_token_file_present : bool;
  admin_token_env_configured : bool;
  admin_token_env_status : string;
  admin_token_env_agent : string option;
  admin_token_env_role : string option;
  token_bound_admin_http_ready : bool;
  admin_bearer_sources : string list;
  credential_count : int;
  role_counts : (string * int) list;
  watched_agents : watched_agent list;
  codex_mcp : codex_mcp;
  mcp_clients : mcp_client list;
  warnings : string list;
  next_actions : string list;
}
(** Auth-doctor aggregate report.  Concrete record because
    callers (tests + CLI rendering) destructure fields directly
    ([report.status], [report.token_bound_admin_http_ready],
    [report.warnings], etc.).  25 fields; new fields go through
    this contract. *)

(** {1 Analysis + rendering} *)

val analyze :
  base_path_input:string ->
  default_base_path:string ->
  unit ->
  t
(** [analyze ~base_path_input ~default_base_path ()] inspects:

    + Resolved auth directory under [base_path_input] /
      [default_base_path] (caller-supplied path, with fallback
      so the diagnostic still runs in unconfigured environments).
    + Each registered agent credential -> {!watched_agent} row.
    + Admin-token env-var status + admin-bearer source
      enumeration ([admin_bearer_sources]).
    + Codex MCP config via {!Codex_mcp_config_doctor}.
    + Local MCP client identities for Codex, Claude, and Gemini.

    Side-effecting (file reads); pure with respect to the
    process registry — does not mutate auth state. *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson report] renders [report] as a JSON object
    suitable for tool output and dashboard consumption.  Uses
    private per-record encoders that mirror the OCaml record
    field names. *)

val render_text : t -> string
(** [render_text report] returns a human-readable multi-line
    text rendering with section headers and bullet lists.  Used
    by the CLI [auth doctor] subcommand. *)

val exit_code : t -> int
(** [exit_code report] returns the suggested process exit code:

    - {!Ok} -> [0]
    - {!Warn} -> [1] (warnings fail CI — drift to permissive
      [0] would silently swallow auth misconfiguration alerts)
    - {!Error} -> [1]

    Pinned at the contract seam: only {!Ok} status returns 0.
    Drift would change CI pass/fail behaviour for the
    [auth-doctor] gate. *)
