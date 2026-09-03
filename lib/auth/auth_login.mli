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
    5. Renders dashboard / MCP URLs using URL-encoded query params.
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
  | Expires_in_hours of int
        (** Token expires [hours] from now, whatever the auth config
            says. For a client that outlives an operator session but
            should still lose its bearer eventually — it can mint a
            replacement on its next start. A window outside 1..8760
            hours makes {!mint} return an error. *)

val lifetime_of_flags :
  no_expiry:bool -> expiry_hours:int option -> (token_lifetime, string) result
(** The lifetime an operator asked for, read off the two command-line flags
    that can name one. Naming both is an error rather than a precedence rule:
    whichever flag lost would hand back a credential the operator did not ask
    for. Naming neither leaves the workspace's own window. *)

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
    - [dashboard_url] always carries [agent] + [token] query params,
      both URL-encoded.
    - [mcp_token_env_var] is exactly the value the caller passed to
      {!mint} via [~token_env_var]. The server does not interpret
      or validate this string — it is rendered verbatim into the
      [export] statements and JSON output. *)

(** {1 Mint entry point} *)

val read_persisted_token :
  base_path:string -> agent_name:string -> string option
(** The bearer [masc login] persisted for [agent_name] in this workspace, or
    [None] when the file is absent or empty. Token persistence is otherwise
    private to this module; the reader is exposed because a local client
    should find its own credential where login wrote it rather than require
    the operator to re-export it into every shell. *)

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
    - [~token_lifetime] picks the expiry policy: the workspace's
      own window, none at all, or a window the caller names. The
      server does not infer this from [agent_name] — the caller
      decides.

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

type mcp_client =
  | Codex  (** bearer-env TOML block, e.g. Codex-style clients. *)
  | Claude_desktop  (** [mcpServers] JSON that bridges over [mcp-remote]. *)
  | Env  (** shell exports, for any client that reads the token from env. *)

val mcp_client_of_string : string -> mcp_client option
(** ["codex"] / ["claude-desktop"] / ["env"], or [None] for any other name. *)

val render_mcp_client_config : t -> mcp_client -> string
(** [render_mcp_client_config report client] returns a ready configuration
    block for [client], carrying [report]'s [mcp_url], [mcp_token_env_var], and
    minted bearer, so a client can connect without hand-wiring the URL, token,
    and header. [Env] delegates to {!render_shell}; the other two embed the raw
    bearer in the block the client reads, matching the documented shapes in
    [docs/MCP-TEMPLATE.md] and the README. *)

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
