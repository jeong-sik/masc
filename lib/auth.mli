(** Authentication & Authorization — token lifecycle, credential management,
    and permission enforcement for MASC agents.

    Types ([auth_config], [agent_credential], [masc_error], [agent_role],
    [permission]) are re-exported from the [Types] module via [open Types].

    @since 0.4.0 *)

open Types

(** {1 Token Generation} *)

(** Generate a cryptographically random hex token (64 chars). *)
val generate_token : unit -> string

(** Hash a token/secret with SHA-256 and return lowercase hex. *)
val sha256_hash : string -> string

(** [save_private_text_file path content] writes [content] to [path] with
    mode 0o600. Creates the file if missing, truncates otherwise. *)
val save_private_text_file : string -> string -> unit

(** {1 Path Helpers} *)

val auth_dir : string -> string
val agents_dir : string -> string
val room_secret_file : string -> string
val auth_config_file : string -> string
val credential_file : string -> string -> string
val internal_keeper_token_hash_file : string -> string
val internal_keeper_token_env_key : string

(** {1 Auth Config} *)

(** [load_auth_config config] reads [.masc/auth/config.json] under [config].
    Returns [default_auth_config] on missing / parse errors. *)
val load_auth_config : string -> auth_config

(** [save_auth_config config cfg] persists the auth config. *)
val save_auth_config : string -> auth_config -> unit

(** {1 Credentials} *)

(** [load_credential config agent_name] looks up the agent's credential.
    Falls back to agent-type prefix for generated nicknames. *)
val load_credential : string -> string -> agent_credential option

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
  | Credential_mismatch of
      { ctx_agent_name : string
      ; resolved_credential_stem : string
      }

val pp_load_credential_error : Format.formatter -> load_credential_error -> unit
val show_load_credential_error : load_credential_error -> string

(** [load_credential_of config ~ctx_agent_name ~resolved_credential_stem]
    looks up a keeper credential and {b rejects identity drift
    explicitly}.

    Caller is responsible for resolving the requested alias to a
    [resolved_credential_stem] before calling — typically through
    {!Keeper_identity.normalize_all_names} on the dispatch site.  This
    keeps [Auth] free of any dependency on [Keeper_identity] (the
    inverse direction is required by P3 preflight, so Auth → Keeper
    would be a cycle).

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

    This replaces the silent fallback in {!load_credential_with_aliases}
    where a stem of [sangsu] against a [ctx_agent_name] of
    [keeper-sangsu-agent] would return the bare-nickname credential and
    perpetuate dual identity.  Callers that still need the legacy
    behavior keep using {!load_credential_with_aliases}; new dispatcher
    paths should adopt [load_credential_of] one site at a time
    (RFC P2-b through P2-d). *)
val load_credential_of
  :  string
  -> ctx_agent_name:string
  -> resolved_credential_stem:string
  -> (agent_credential, load_credential_error) result

val save_credential : string -> agent_credential -> unit

(** #10440: write a short-form alias [<alias_name>.json] as a
    redirect stub pointing at the same UUID file as the existing
    [<canonical_name>.json] credential.  Idempotent — a stub
    already pointing at the canonical UUID is a no-op.

    Returns [Error] if the canonical credential is missing or is
    itself a direct (non-redirect) credential, since alias
    semantics require a UUID-backed canonical. *)
val ensure_credential_alias
  :  string
  -> canonical_name:string
  -> alias_name:string
  -> (unit, Types.masc_error) result

val delete_credential : string -> string -> unit
val list_credentials : string -> agent_credential list

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
val audit_token_uniqueness : string -> (string * string list) list

(** Outcome of one shared-token rotation group.  [token_hash_prefix]
    matches the corresponding entry from {!audit_token_uniqueness}.
    [rotated_agents] reports each agent in declaration order: the
    [Ok ()] case means a fresh per-agent credential was written,
    [Error _] preserves the failure (typically I/O during
    [save_credential]) without aborting the whole batch.  Callers
    that want strict atomicity should retry on partial failure. *)
type rotation_outcome =
  { token_hash_prefix : string
  ; rotated_agents : (string * (unit, masc_error) result) list
  }

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
val rotate_shared_tokens : string -> rotation_outcome list

(** Guarded variant of {!rotate_shared_tokens}.  Only credentials
    whose [agent_name] is present in [agent_names] are eligible for
    rotation.  Boot-time keeper repair uses this to avoid rotating
    operator/admin tokens while still breaking shared keeper bearer
    groups. *)
val rotate_shared_tokens_for_agents
  :  string
  -> agent_names:string list
  -> rotation_outcome list

val find_credential_by_token
  :  string
  -> token:string
  -> (agent_credential, masc_error) result

val resolve_agent_from_token : string -> token:string -> (string, masc_error) result

(** {1 Raw Token Credential} *)

(** [save_raw_token_credential config ~agent_name ~role ~raw_token] hashes the
    raw token and persists the credential. *)
val save_raw_token_credential
  :  string
  -> agent_name:string
  -> role:agent_role
  -> raw_token:string
  -> (agent_credential, masc_error) result

val verify_internal_keeper_token : string -> token:string -> bool
val ensure_internal_keeper_token : string -> string

(** [ensure_keeper_credential config ~agent_name] returns a valid credential,
    backed by a per-keeper raw bearer token file.  The internal
    keeper MCP token remains separate and is only used for the
    [x-masc-internal-token] trust path. *)
val ensure_keeper_credential
  :  string
  -> agent_name:string
  -> (string * agent_credential, masc_error) result

(** {1 Token Lifecycle} *)

(** [create_token config ~agent_name ~role] returns [(raw_token, credential)]. *)
val create_token
  :  string
  -> agent_name:string
  -> role:agent_role
  -> (string * agent_credential, masc_error) result

val verify_token
  :  string
  -> agent_name:string
  -> token:string
  -> (agent_credential, masc_error) result

val refresh_token
  :  string
  -> agent_name:string
  -> old_token:string
  -> (string * agent_credential, masc_error) result

(** {1 Permission Checks} *)

val check_permission
  :  string
  -> agent_name:string
  -> token:string option
  -> permission:permission
  -> (unit, masc_error) result

val permission_for_tool : string -> permission option
val is_tool_auth_strict_enabled : unit -> bool

val authorize_tool
  :  string
  -> agent_name:string
  -> token:string option
  -> tool_name:string
  -> (unit, masc_error) result

(** {1 Role Resolution} *)

val resolve_role
  :  string
  -> agent_name:string
  -> token:string option
  -> (agent_role, masc_error) result

val resolve_role_with_auth_config
  :  string
  -> auth_cfg:auth_config
  -> agent_name:string
  -> token:string option
  -> (agent_role, masc_error) result

val authorize_tool_for_role
  :  agent_name:string
  -> role:agent_role
  -> tool_name:string
  -> (unit, masc_error) result

val authorize_tool_v2
  :  string
  -> agent_name:string
  -> token:string option
  -> tool_name:string
  -> (unit, masc_error) result

(** {1 Room Secret} *)

(** [init_room_secret config] generates and persists a room secret.
    Returns the raw secret (shown once). *)
val init_room_secret : string -> string

val verify_room_secret : string -> string -> bool

(** {1 Auth Toggle} *)

(** [enable_auth config ~require_token ~agent_name] returns
    [(room_secret, bootstrap_token)]. *)
val enable_auth
  :  string
  -> require_token:bool
  -> agent_name:string
  -> string * string option

val disable_auth : string -> unit
val is_auth_enabled : string -> bool

(** [read_initial_admin config] returns the bootstrap admin agent name. *)
val read_initial_admin : string -> string option

(** {1 Nickname Helpers} *)

val extract_agent_type_prefix : string -> string option
