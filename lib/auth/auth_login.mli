(** Auth_login — bearer-token mint and login-report rendering for
    [masc login].

    Single mint entry point ({!mint}) that:
    1. Initialises the Mirage RNG idempotently.
    2. Ensures the auth config has bearer auth required (creating
       it when absent, flipping [require_token] when not yet on).
    3. Mints a bearer token via {!Auth.create_token} (or the
       no-expiry variant when [~token_lifetime] is [`Long_lived]).
    4. Persists the raw token to a per-agent file under
       [<base_path>/.masc/auth/<agent_name>.token].
    5. Renders a dashboard URL carrying only the non-secret agent hint and an
       MCP endpoint URL carrying no credentials.
    6. Returns a {!t} record carrying every field needed by the
       three render functions ({!to_yojson}, {!render_shell},
       {!render_text}).

    All internal helpers (URL encoding, shell quoting, RNG init,
    config-flip, token persistence) stay private — the four entry
    points cover every documented [masc login] consumer (CLI,
    JSON API, shell-export).

    The server is client-agnostic: the caller (CLI / API consumer)
    supplies the env var name ([~token_env_var]) and the
    token-lifetime policy ([~token_lifetime]). This module holds
    no list of "known" MCP clients — those conventions live in the
    operator's wrapper scripts and the runbook, not in server code. *)

(** {1 Auth configuration change taxonomy} *)

type auth_change =
  | Auth_already_required
        (** Bearer auth was already enabled with [require_token]. *)
  | Auth_enabled
        (** Bearer auth was disabled; this call enabled it. *)
  | Require_token_enabled
        (** Bearer auth was enabled but [require_token] was off;
            this call flipped it on. *)

(** {1 Token lifetime policy} *)

type token_lifetime =
  | With_expiry
        (** Token uses the default expiry window from the auth
            config (see {!Auth.create_token}). Appropriate for
            short-lived operator sessions. *)
  | Long_lived
        (** Token has no [expires_at]; appropriate for long-running
            local MCP daemons that cannot easily refresh on expiry.
            The decision to use this lifetime is the caller's —
            this module never infers it from [agent_name]. *)

(** {1 Login report} *)

type t = {
  base_path : string;
  auth_config_path : string;
  auth_change : auth_change;
  agent_name : string;
  role : Masc_domain.agent_role;
  bearer_token : string;
  raw_token_file : string;
  dashboard_url : string;
  mcp_url : string;
  mcp_token_env_var : string;
}
(** Concrete record because the test suite ({!test_auth_login}) and
    the CLI entrypoint read individual fields
    ([report.agent_name], [report.bearer_token], [report.raw_token_file]).

    Field invariants:
    - [bearer_token] is the freshly-minted raw token; it is also
      written to [raw_token_file] (operator-readable, mode 0600).
    - [dashboard_url] carries only the URL-encoded [agent] hint. The bearer
      token is never embedded in a URL; browser callers supply it through the
      dashboard auth control, which sends it in the Authorization header.
    - [mcp_token_env_var] is exactly the value the caller passed to
      {!mint} via [~token_env_var]. The server does not interpret
      or validate this string — it is rendered verbatim into the
      [export] statements and JSON output. *)

(** {1 Mint entry point} *)

val mint :
  base_path:string ->
  host:string ->
  port:int ->
  agent_name:string ->
  role:Masc_domain.agent_role ->
  token_env_var:string ->
  token_lifetime:token_lifetime ->
  unit ->
  (t, Masc_error.t) result
(** [mint ~base_path ~host ~port ~agent_name ~role ~token_env_var
        ~token_lifetime ()] runs the full login lifecycle.

    {2 Required arguments}
    - [~token_env_var] is the operator's chosen env var name (e.g.
      ["MASC_TOKEN"] or any operator-chosen variant). The server
      does not pick a default — the caller decides. The string is
      embedded verbatim in shell / JSON / text output.
    - [~token_lifetime] selects between expiring and long-lived
      credentials. The server does not infer this from
      [agent_name] — the caller decides.

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
    [raw_token_file] / [dashboard_url] / [mcp_url] / [mcp_client]. *)

val render_shell : t -> string
(** [render_shell report] returns four newline-separated [export]
    statements suitable for [eval] in a POSIX shell:

    - [MASC_OPERATOR_AGENT]
    - [MASC_OPERATOR_TOKEN]
    - [<mcp_token_env_var>] (caller-supplied env var name)
    - [MASC_DASHBOARD_URL]

    All values are POSIX-quoted (single-quoted with embedded
    single-quotes escaped via the standard ['\\''] sequence) so the
    output is safe for unattended sourcing. *)

val render_text : t -> string
(** [render_text report] returns a multi-line human-readable summary
    suitable for terminal display: status / base_path /
    auth_config_path / auth_change / agent_name / role /
    raw_token_file / dashboard_url / mcp_url, then the shell
    [exports:] block (from {!render_shell}), then [mcp_client:]
    block describing the bearer-token-env auth model.

    The bearer token itself is intentionally NOT included as a
    standalone line in the text output — it appears only inside
    the [exports:] block, so an operator who pipes the output
    through `tee` to a shared log does not leak the token via
    a standalone "bearer_token: ..." line. *)
