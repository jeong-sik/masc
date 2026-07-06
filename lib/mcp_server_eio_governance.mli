(** Mcp_server_eio_governance — governance configuration and
    MCP session helpers.

    Extracted from [mcp_server_eio.ml] to reduce file size and
    enable reuse from {!Mcp_tool_runtime} without
    re-introducing the dependency cycle the split was designed
    to break. {!Mcp_server_eio} re-exports the two record types
    via [type t = Mcp_server_eio_governance.t = { … }] and
    forwards [governance_defaults] /
    [mcp_session_{to,of}_json] as top-level lets.

    Internal helpers (the [governance_path] / [mcp_sessions_path]
    path joiners) are
    hidden — callers go through [load_*] / [save_*] which call
    them on every read / write. The auto-derived
    [mcp_session_record_to_yojson] /
    [mcp_session_record_of_yojson] are also hidden; the
    [mcp_session_{to,of}_json] aliases are the canonical names. *)

(** {1 Governance} *)

type governance_config = {
  level : string;
  audit_enabled : bool;
  anomaly_detection : bool;
}
(** Process-wide governance posture. The fields are public so
    {!Mcp_server_eio} can rebind the type via the [type … = … =
    { … }] equality pattern; tests in
    [test_governance_yojson_roundtrip] also construct the record
    directly. *)

val governance_config_to_yojson : governance_config -> Yojson.Safe.t
(** [@@deriving yojson]-generated encoder. Exposed because the
    round-trip test suite asserts on the output and
    {!save_governance} composes the result with an
    [updated_at] field before persisting. *)

val governance_config_of_yojson :
  Yojson.Safe.t -> (governance_config, string) result
(** [@@deriving yojson { strict = false }]-generated decoder.
    Strict-false: unknown fields are tolerated to keep older
    [governance.json] payloads readable across upgrades. *)

val governance_defaults : string -> governance_config
(** Resolve a {!governance_config} from a level name (case
    insensitive). The level is canonicalised to lowercase in
    [level], and the two boolean fields are derived:

    - [audit_enabled = true] iff [level] is
      ["production"] / ["enterprise"] / ["paranoid"]
    - [anomaly_detection = true] iff [level] is
      ["enterprise"] / ["paranoid"]

    Every other level (including ["development"], the implicit
    fallback) leaves both flags [false]. *)

val load_governance : Workspace.config -> governance_config
(** Read [governance.json] under [config]'s [.masc/] root. When
    the file is absent, returns
    [governance_defaults "development"]. Per-field fallback to
    {!governance_defaults} of the JSON's [level] is applied so a
    partial file does not bring the boolean flags to their
    [false] defaults. *)

val save_governance :
  Workspace.config -> governance_config -> unit
(** Persist [g] to [governance.json] under [config]'s [.masc/]
    root. The [updated_at] field is appended (current
    [Masc_domain.now_iso ()]) when the encoder produces an [`Assoc].
    Creates the [.masc/] directory if absent. *)

val save_governance_result :
  Workspace.config -> governance_config -> (unit, string) result
(** Result-returning variant of {!save_governance}. *)

(** {1 MCP sessions} *)

type mcp_session_record = {
  id : string;
  agent_name : string option;
  created_at : float;
  last_seen : float;
}
(** A single persisted MCP session row. [agent_name] defaults to
    [None] when absent in JSON via the [@default None] derive
    attribute. *)

val mcp_session_to_json : mcp_session_record -> Yojson.Safe.t
(** Canonical encoder name used by callers; aliases the
    auto-derived [mcp_session_record_to_yojson] which is hidden
    to keep the surface stable across PPX renames. *)

val mcp_session_of_json :
  Yojson.Safe.t -> mcp_session_record option
(** Canonical decoder name. Returns [None] on any decode
    failure (the auto-derived
    [mcp_session_record_of_yojson]'s [Result.t] is collapsed
    via [Result.to_option] because callers always treat decode
    failure as "skip this row"). *)

val load_mcp_sessions : Workspace.config -> mcp_session_record list
(** Read [mcp-sessions.json] under [config]'s [.masc/] root.
    Returns [[]] when the file is absent or when the top-level
    JSON is not a [`List]. Individual rows that fail to decode
    are silently dropped — callers must not rely on a complete
    list across schema migrations. *)

val save_mcp_sessions :
  Workspace.config -> mcp_session_record list -> unit
(** Persist [sessions] as a [`List] to [mcp-sessions.json] under
    [config]'s [.masc/] root. Creates the [.masc/] directory if
    absent. *)

val save_mcp_sessions_result :
  Workspace.config -> mcp_session_record list -> (unit, string) result
(** Result-returning variant of {!save_mcp_sessions}. *)
