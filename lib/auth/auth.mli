(** Authentication & Authorization — token lifecycle, credential management,
    and permission enforcement for MASC agents.

    Types ([auth_config], [agent_credential], [masc_error], [agent_role],
    [permission]) are re-exported from the [Types] module via [open Masc_domain].

    @since 0.4.0 *)

open Masc_domain

(** {1 Token Generation} *)

val generate_token : unit -> string
(** Generate a cryptographically random hex token (64 chars). *)

val sha256_hash : string -> string
(** Hash a token/secret with SHA-256 and return lowercase hex. *)

val save_private_text_file : string -> string -> unit
(** [save_private_text_file path content] writes [content] to [path] with
    mode 0o600. Creates the file if missing, truncates otherwise. *)

(** {1 Path Helpers} *)

val auth_dir : string -> string
val agents_dir : string -> string
val workspace_secret_file : string -> string
val auth_config_file : string -> string
val credential_file : string -> string -> string
val internal_keeper_token_hash_file : string -> string
val internal_keeper_token_env_key : string
val extract_agent_type_prefix : string -> string option
val save_internal_keeper_token_hash : string -> raw_token:string -> unit

(** {1 Auth Config} *)

val load_auth_config : string -> auth_config
(** [load_auth_config config] reads [.masc/auth/config.json] under [config].
    Returns [default_auth_config] on missing / parse errors. *)

val save_auth_config : string -> auth_config -> unit
(** [save_auth_config config cfg] persists the auth config. *)

(** {1 Credentials} *)

val load_credential : string -> string -> agent_credential option
(** [load_credential config agent_name] looks up the agent's credential.
    Falls back to agent-type prefix for generated nicknames. *)

(** Outcome of {!load_credential_of}: distinguishes "no credential file
    at all" from "credential found but its owner does not match the
    dispatcher-validated [ctx_agent_name]".  The second case is the
    {b dual identity} mode where {!load_credential} silently returned a
    credential whose [agent_name] differs from the caller's claimed
    identity (e.g. requested [sangsu] resolves to bare-nickname cred
    while [ctx_agent_name] is [keeper-sangsu-agent]).
    [load_credential_of] surfaces the mismatch instead of
    perpetuating it. *)
type load_credential_error =
  | Credential_missing of { ctx_agent_name : string }
  | Credential_mismatch of {
      ctx_agent_name : string;
      resolved_credential_stem : string;
    }

val pp_load_credential_error :
  Format.formatter -> load_credential_error -> unit

val show_load_credential_error : load_credential_error -> string

val load_credential_of :
  string ->
  ctx_agent_name:string ->
  resolved_credential_stem:string ->
  (agent_credential, load_credential_error) result
(** [load_credential_of config ~ctx_agent_name ~resolved_credential_stem]
    looks up a keeper credential and {b rejects identity drift
    explicitly}.

    Caller is responsible for resolving the requested alias to a
    [resolved_credential_stem] before calling. This keeps [Auth] free
    of any dependency on [Keeper_identity].

    Branches (RFC §2.2, adjusted for the dependency direction):
    {ul
    {- [resolved_credential_stem = ctx_agent_name] — load directly.
       Returns [Error (Credential_missing _)] on absence.}
    {- otherwise — return [Error (Credential_mismatch _)] {b without}
       falling back to a different identity, even when a credential
       for [resolved_credential_stem] exists on disk.}}

    Convention: when the caller has nothing to resolve (empty alias or
    alias already equal to ctx), it should pass [ctx_agent_name] as
    [resolved_credential_stem]; the function then degenerates to a
    simple exact-match lookup with explicit error variants.

    This replaces the removed silent alias fallback
    where a stem of [sangsu] against a [ctx_agent_name] of
    [keeper-sangsu-agent] would return the bare-nickname credential and
    perpetuate dual identity. *)

val save_credential : string -> agent_credential -> unit

val ensure_credential_alias :
  string ->
  canonical_name:string ->
  alias_name:string ->
  (unit, Masc_domain.masc_error) result
(** #10440: write a short-form alias [<alias_name>.json] as a
    redirect stub pointing at the same UUID file as the existing
    [<canonical_name>.json] credential.  Idempotent — a stub
    already pointing at the canonical UUID is a no-op.

    Returns [Error] if the canonical credential is missing or is
    itself a direct (non-redirect) credential, since alias
    semantics require a UUID-backed canonical. *)

val delete_credential : string -> string -> unit

val list_credentials : string -> agent_credential list

val audit_token_uniqueness : string -> (string * string list) list
(** #9786: walk all credentials under [config] and return groups of
    agent names that share the same token hash.  Each entry is
    [(token_hash_prefix, agent_names)] where [agent_names] has at
    least 2 elements (a unique token would not appear in the
    result).  [token_hash_prefix] is the first 12 chars of the
    SHA-256 hash, so logs / dashboards can correlate without
    leaking the full credential.

    Used at server bootstrap to surface the
    [bearer-token-belongs-to-X] failure mode (#9786) BEFORE
    runtime requests start failing.  Empty list = healthy. *)

(** Outcome of one shared-token rotation group.  [token_hash_prefix]
    matches the corresponding entry from {!audit_token_uniqueness}.
    [rotated_agents] reports each agent in declaration order: the
    [Ok ()] case means a fresh per-agent credential was written,
    [Error _] preserves the failure (typically I/O during
    [save_credential]) without aborting the whole batch.  Callers
    that want strict atomicity should retry on partial failure. *)
type rotation_outcome = {
  token_hash_prefix : string;
  rotated_agents : (string * (unit, masc_error) result) list;
}

val rotate_shared_tokens : string -> rotation_outcome list
(** #10304 follow-up to #9786: when {!audit_token_uniqueness} reports
    a group of agents sharing one bearer token, generate a fresh
    unique token for EACH agent in the group and persist the
    credential plus its raw token file.  Returns one
    [rotation_outcome] per group, in the same order as the audit, so
    callers can attach a structured WARN or counter to every
    rotation.

    A single shared-token incident on the production fleet flips
    14 keeper credentials at once (#10304 evidence: 3 distinct
    [token_hash_prefix] each shared by 14 agents in a single day),
    so this is intended as an opt-in escalation: detection
    (audit_token_uniqueness) stays the default; explicit rotation
    is what an operator or a guarded boot path drives.

    Note: rotating an agent's token forces every running consumer
    of that token to re-fetch credentials.  Callers should hold
    rotation to boot-time or operator-driven contexts where the
    re-auth burst is acceptable. *)

val rotate_shared_tokens_for_agents :
  string -> agent_names:string list -> rotation_outcome list
(** Guarded variant of {!rotate_shared_tokens}.  Only credentials
    whose [agent_name] is present in [agent_names] are eligible for
    rotation.  Boot-time keeper repair uses this to avoid rotating
    operator/admin tokens while still breaking shared keeper bearer
    groups. *)

val find_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result

(** Structured description of which credential fields differ between two
    credentials that share the same token hash. *)
type credential_field_diff =
  | Agent_name of { left : string; right : string }
  | Role of { left : agent_role; right : agent_role }
  | Created_at of { left : string; right : string }
  | Expires_at of { left : string option; right : string option }
  | Agent_id of { left : string option; right : string option }
  | Credential_id of { left : string option; right : string option }
  | Token_hash of { left : string; right : string }

(** Observability payload emitted when two credentials hash to the same
    value but are not identical. *)
type collision_log = {
  token_hash_prefix : string;
  left_agent : string;
  right_agent : string;
  field_diffs : credential_field_diff list;
}

(** Pure comparison result: [Equal] means the two credentials are
    identical on every field; [Different log] carries a typed record
    of the divergence. *)
type credential_comparison =
  | Equal
  | Different of collision_log

(** Compare two credentials field-by-field.  The caller supplies the
    token hash prefix for the collision log; the comparison itself is
    pure and depends only on the two records. *)
val compare_credentials :
  token_hash_prefix:string -> agent_credential -> agent_credential -> credential_comparison

val resolve_agent_from_token :
  string -> token:string -> (string, masc_error) result

(** {1 Raw Token Credential} *)

val save_raw_token_credential :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result
(** [save_raw_token_credential config ~agent_name ~role ~raw_token] hashes the
    raw token and persists the credential. *)

val save_raw_token_credential_without_expiry :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result
(** [save_raw_token_credential_without_expiry config ~agent_name ~role
    ~raw_token] persists a credential with [expires_at = None].  Use this for
    local MCP client bearers backed by private token files, not for
    operator-issued session tokens. *)

val load_raw_token : string -> agent_name:string -> string option
(** [load_raw_token base_path ~agent_name] reads the raw bearer token from
    [<base_path>/.masc/auth/<agent_name>.token] if present. Returns [None] if
    the file is missing, empty after trim, or unreadable. Used by
    [oas_worker_exec_transport] as a fallback for CLI subprocesses that do
    not inherit the parent's [MASC_TOKEN] env. *)

val verify_internal_keeper_token :
  string -> token:string -> bool

val ensure_internal_keeper_token :
  string -> string

val ensure_keeper_credential :
  string -> agent_name:string ->
  (string * agent_credential, masc_error) result
(** [ensure_keeper_credential config ~agent_name] returns a valid credential,
    backed by a per-keeper raw bearer token file.  The internal
    keeper MCP token remains separate and is only used for the
    [x-masc-internal-token] trust path. *)

type credential_status =
  | Credential_present of agent_credential
  | Credential_missing

val audit_keeper_credentials :
  string -> keeper_names:string list ->
  (string * credential_status) list
(** Read-only audit: for each [keeper_name] in [keeper_names], report
    whether a credential file exists at [.masc/auth/agents/<n>.json].
    Used at boot to emit one structured summary instead of
    enumerating individual fail logs.  Does NOT mutate any state;
    [ensure_keeper_credential] / [ensure_credential_alias] remain
    the write paths. *)

(** {1 Token Lifecycle} *)

val create_token :
  string -> agent_name:string -> role:agent_role ->
  (string * agent_credential, masc_error) result
(** [create_token config ~agent_name ~role] returns [(raw_token, credential)]. *)

val create_token_without_expiry :
  string -> agent_name:string -> role:agent_role ->
  (string * agent_credential, masc_error) result
(** [create_token_without_expiry config ~agent_name ~role] returns a fresh raw
    token and non-expiring credential for local MCP client identity sync. *)

val verify_token :
  string -> agent_name:string -> token:string ->
  (agent_credential, masc_error) result

val refresh_token :
  string -> agent_name:string -> old_token:string ->
  (string * agent_credential, masc_error) result

(** {1 Permission Checks} *)

val check_permission :
  string -> agent_name:string -> token:string option ->
  permission:permission -> (unit, masc_error) result

val is_tool_auth_strict_enabled : unit -> bool

val authorize_tool :
  string -> agent_name:string -> token:string option ->
  tool_name:string -> (unit, masc_error) result

(** {1 Role Resolution} *)

val resolve_role :
  string -> agent_name:string -> token:string option ->
  (agent_role, masc_error) result

val resolve_role_with_auth_config :
  string -> auth_cfg:auth_config -> agent_name:string -> token:string option ->
  (agent_role, masc_error) result

val authorize_tool_for_role :
  agent_name:string -> role:agent_role -> tool_name:string ->
  (unit, masc_error) result

val authorize_tool_v2 :
  string -> agent_name:string -> token:string option ->
  tool_name:string -> (unit, masc_error) result

(** {1 Workspace Secret} *)

val init_workspace_secret : string -> string
(** [init_workspace_secret config] generates and persists a workspace secret.
    Returns the raw secret (shown once). *)

val verify_workspace_secret : string -> cached_hash:string option -> string -> bool
(** [verify_workspace_secret config ~cached_hash secret] checks [secret]
    against [cached_hash] (the caller's already-loaded [auth_config.
    workspace_secret_hash]) using a constant-time comparison. Falls back to
    a guarded read of the on-disk workspace-secret file only when
    [cached_hash] is [None]; that fallback fails closed on any read error
    rather than raising. *)

(** {1 Auth Toggle} *)

val enable_auth :
  string -> require_token:bool -> agent_name:string ->
  string * string option
(** [enable_auth config ~require_token ~agent_name] returns
    [(workspace_secret, bootstrap_token)]. *)

val disable_auth : string -> unit

val is_auth_enabled : string -> bool

val read_initial_admin : string -> string option
(** [read_initial_admin config] returns the bootstrap admin agent name. *)
