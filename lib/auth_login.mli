(** Auth_login — bearer-token mint and login-report rendering for
    [masc-mcp login].

    Single mint entry point ({!mint}) that:
    1. Initialises the Mirage RNG idempotently.
    2. Ensures the auth config has bearer auth required (creating
       it when absent, flipping [require_token] when not yet on).
    3. Mints a bearer token via {!Auth.create_token}.
    4. Persists the raw token to a per-agent file under
       [<base_path>/.masc/auth/<agent_name>.token].
    5. Renders dashboard / MCP URLs using URL-encoded query params.
    6. Returns a {!t} record carrying every field needed by the
       three render functions ({!to_yojson}, {!render_shell},
       {!render_text}).

    All internal helpers (URL encoding, shell quoting, RNG init,
    config-flip, token persistence, hard-coded codex constants) stay
    private — the four entry points cover every documented [masc-mcp
    login] consumer (CLI, JSON API, shell-export). *)

(** {1 Auth configuration change taxonomy} *)

type auth_change =
  | Auth_already_required
        (** Bearer auth was already enabled with [require_token]. *)
  | Auth_enabled
        (** Bearer auth was disabled; this call enabled it. *)
  | Require_token_enabled
        (** Bearer auth was enabled but [require_token] was off;
            this call flipped it on. *)

(** {1 Login report} *)

type t = {
  base_path : string;
  auth_config_path : string;
  auth_change : auth_change;
  agent_name : string;
  role : Types.agent_role;
  bearer_token : string;
  raw_token_file : string;
  dashboard_url : string;
  mcp_url : string;
  mcp_token_env_var : string;
  codex_server_name : string;
  codex_token_env_var : string;
  codex_login_supported : bool;
}
(** Concrete record because the test suite ({!test_auth_login}) and
    the CLI ({!Bin.Main_eio}) read individual fields
    ([report.agent_name], [report.bearer_token], [report.raw_token_file]).

    Field invariants:
    - [bearer_token] is the freshly-minted raw token; it is also
      written to [raw_token_file] (operator-readable, mode 0600).
    - [dashboard_url] always carries [agent] + [token] query params,
      both URL-encoded.
    - [mcp_token_env_var] is the client-specific bearer env var for
      known MCP clients ([claude] -> [MASC_CLAUDE_MCP_TOKEN],
      [gemini] -> [MASC_GEMINI_MCP_TOKEN], Codex ->
      [MASC_MCP_TOKEN]).
    - [codex_server_name] is the constant [["masc"]] and
      [codex_token_env_var] is [["MASC_MCP_TOKEN"]]; both pinned at
      this level so the operator runbook for `codex` integration
      surfaces them through the login output rather than via runtime
      string lookup.
    - [codex_login_supported] is currently always [false] —
      {!render_text} explains the OAuth-only `codex mcp login` and
      directs operators to the bearer-token export instead. *)

(** {1 Mint entry point} *)

val mint :
  base_path:string ->
  host:string ->
  port:int ->
  agent_name:string ->
  role:Types.agent_role ->
  unit ->
  (t, Masc_error.t) result
(** [mint ~base_path ~host ~port ~agent_name ~role ()] runs the full
    login lifecycle.

    {2 Side effects}
    - Initialises Mirage's default RNG on first call (idempotent
      via an internal [Atomic.t] flag — safe across concurrent
      invocations).
    - Mutates the auth config under [base_path] to enable bearer
      auth + [require_token] when not already on. The reported
      {!auth_change} reflects which transition occurred.
    - Creates the auth directory and writes the raw token to
      [<base_path>/.masc/auth/<agent_name>.token] with restrictive
      permissions (delegated to {!Auth.save_private_text_file}).

    {2 Errors}
    Returns [Error err] when {!Auth.create_token} fails (typically
    because [agent_name] does not match the auth-config schema or
    because the role is unauthorised at this base_path). The
    {!Masc_error.t} carries the operator-visible message that the
    CLI / API caller renders into the JSON-RPC error envelope.

    {2 base_path normalisation}
    [base_path] is normalised through
    {!Env_config_core.normalize_masc_base_path_input} before any
    file-system access, so callers may pass user-typed paths (with
    or without trailing slash, with [~] expansion). *)

(** {1 Rendering} *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson report] renders the canonical JSON-RPC result
    object with fields [status: "ok"] / [base_path] / [auth_config_path]
    / [auth_change] / [agent_name] / [role] / [bearer_token] /
    [raw_token_file] / [dashboard_url] / [mcp_url] / [mcp_client] /
    [codex_mcp].

    The [codex_mcp] sub-object pins five fields: [server_name],
    [auth_model: "bearer_token_env"], [token_env_var],
    [login_supported], and a [login_note] explaining the OAuth-only
    `codex mcp login`.  The literal note string is part of the
    operator-visible contract — runbooks reference it by exact
    wording. *)

val render_shell : t -> string
(** [render_shell report] returns four newline-separated [export]
    statements suitable for [eval] in a POSIX shell:

    - [MASC_OPERATOR_AGENT]
    - [MASC_OPERATOR_TOKEN]
    - [<mcp_token_env_var>] (client-specific for Claude/Gemini/Codex)
    - [MASC_DASHBOARD_URL]

    All values are POSIX-quoted (single-quoted with embedded
    single-quotes escaped via the standard ['\\''] sequence) so the
    output is safe for unattended sourcing. *)

val render_text : t -> string
(** [render_text report] returns a multi-line human-readable summary
    suitable for terminal display: status / base_path /
    auth_config_path / auth_change / agent_name / role /
    raw_token_file / dashboard_url / mcp_url, then the shell
    [exports:] block (from {!render_shell}), then [mcp_client:] and
    [codex_mcp:] blocks describing the bearer-token-env auth model.

    The bearer token itself is intentionally NOT included as a
    standalone line in the text output — it appears only inside
    the [exports:] block, so an operator who pipes the output
    through `tee` to a shared log does not leak the token via
    a standalone "bearer_token: ..." line. *)
