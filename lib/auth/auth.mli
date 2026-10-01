(** Authentication & Authorization — token lifecycle, credential management,
    and permission enforcement for MASC agents.

    Types ([auth_config], [agent_credential], [masc_error], [agent_role],
    [permission]) are re-exported from the [Types] module via [open Masc_domain].

    @since 0.4.0 *)

open Masc_domain

module Regular_read_for_testing : sig
  val read_with_open :
    open_file:(string -> Unix.open_flag list -> int -> Unix.file_descr) ->
    string -> (string, masc_error) result
  (** Exercise the production descriptor reader with a deterministic open
      boundary; no process-wide hook or production reader is changed. *)
end

(** {1 Token Generation} *)

val generate_token : unit -> string
(** Generate a cryptographically random token: exactly 64 lowercase hex
    characters encoding 32 random bytes. *)

val is_generated_token_shape : string -> bool
(** [is_generated_token_shape raw] checks the exact lexical shape produced by
    {!generate_token}. It does not establish token provenance or validity. *)

val sha256_hash : string -> string
(** Hash a token/secret with SHA-256 and return exactly 64 lowercase hex
    characters. Secret comparisons use Eqaf on this fixed-width form. *)

val save_private_text_file : string -> string -> unit
(** [save_private_text_file path content] writes [content] to [path] with
    mode 0o600 using an fsynced sibling replacement. *)

(** {1 Path Helpers} *)

val auth_dir : string -> string
val workspace_secret_file : string -> string
val auth_config_file : string -> string
val credential_file : string -> string -> string
val internal_keeper_token_hash_file : string -> string
val internal_keeper_token_env_key : string

val internal_keeper_token : unit -> string option
(** The internal keeper token this process ensured at boot, as a typed
    in-process value. [None] before {!ensure_internal_keeper_token} has
    run. In-process consumers use this; the env var remains only as the
    cross-process surface. *)
val extract_agent_type_prefix : string -> string option

(** {1 Auth Config} *)

exception Auth_config_error of {
  file : string;
  reason : string;
}

val load_auth_config : string -> auth_config
(** [load_auth_config config] reads [.masc/auth/config.json] under [config].
    An absent path yields {!default_auth_config}. Malformed, unreadable or
    nonregular configuration raises {!Auth_config_error}; dangling links are
    unreadable. Symlinks to regular files are accepted. Cancellation propagates. *)

val save_auth_config : string -> auth_config -> unit
(** [save_auth_config config cfg] persists the auth config. *)

(** {1 Credentials} *)

type credential_transaction
(** An admitted transaction, bound to its workspace. Use it only in the
    callback that received it; it must not escape or be shared with a fiber. *)

val with_credential_transaction :
  string -> (credential_transaction -> 'a) -> ('a, masc_error) result
(** Serialize a credential-dependent effect with credential save, deletion and
    alias publication in this workspace, across fibers, threads and processes.
    The callback may use {!load_credential} and hold its decision through its
    effect. It may delete through {!delete_credential_in_transaction}; other
    credential writers, token-index lookup (whose cold publication also takes
    this lock), and recursive entry would deadlock and must not be called.
    Admission is cancellable; an admitted callback and lock release are protected
    from cancellation. A failed admission runs no callback. A completed callback
    keeps its result if lock cleanup fails, with the cleanup failure logged.
    Body exceptions propagate after release. *)

val credential_exists_in_transaction :
  credential_transaction -> string -> (bool, masc_error) result
(** Check the name file under the caller's admission. Only ENOENT is missing;
    a dangling redirect, symlink or unreadable file still occupies the name. *)

val load_credential : string -> string -> agent_credential option
(** [load_credential config agent_name] reads [agent_name]'s own credential
    file, following its redirect stub to the id-named file. [None] when the
    file is missing, nonregular, or cannot be read or decoded. Symlinks to
    regular files are accepted; cancellation propagates. A name that
    signs in with another name's token (a generated nickname, a Keeper
    transport alias) has no file of its own: the token check maps it to the
    owner ([Auth_credential_token.verify_token_owner_alias]), not this
    lookup. *)

(** Outcome of {!load_credential_of}: distinguishes "no credential file
    at all" from "credential found but its owner does not match the
    dispatcher-validated [ctx_agent_name]".  The second case is the
    {b dual identity} mode where {!load_credential} silently returned a
    credential whose [agent_name] differs from the caller's claimed
    identity (e.g. requested [example-keeper] resolves to bare-nickname cred
    while [ctx_agent_name] is [keeper-example-keeper-agent]).
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
    where a stem of [example-keeper] against a [ctx_agent_name] of
    [keeper-example-keeper-agent] would return the bare-nickname credential and
    perpetuate dual identity. *)

val save_credential : string -> agent_credential -> unit
(** Publish under {!with_credential_transaction}, including token-cache
    invalidation. Lock admission errors raise [Sys_error], like write errors.
    Once a named credential or redirect stub is committed, retirement failures for the
    superseded UUID payload are logged without failing that publication, so a
    caller that minted a bearer can return it. Superseded payloads do not acquire
    named-owner authentication or diagnostic-listing authority. *)

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

val raw_token_file : string -> string -> string
(** [raw_token_file base_path agent_name] is
    [<base_path>/.masc/auth/<agent>.token]. The credential store keeps only a
    SHA-256 of the token, so this file is the one place the bearer itself
    survives a mint — which is what makes its presence worth reporting and its
    removal part of {!delete_credential}. *)

val delete_credential : string -> string -> unit
(** Retire [agent_name]: the credential, its redirect stub and UUID file, and
    the raw token file, then invalidate the credential cache. The bearer stops
    validating from the next request. Absent files are not an error. Redirect
    aliases are refused: request the payload's canonical owner instead. Expiry
    decoding is not required for explicit canonical-owner revocation. *)

val delete_credential_in_transaction :
  credential_transaction -> string -> (unit, masc_error) result
(** The same deletion, using the workspace already admitted by
    {!with_credential_transaction}. No second lock is acquired. Cache
    invalidation also runs if a removal fails after a partial deletion. *)

type credential_listing_error =
  | Invalid_credential_expiry of
      { agent_name : string; role : agent_role; timestamp : string }
  | Unreadable_credential of { path : string; reason : string }

val list_credential_results :
  string -> (agent_credential, credential_listing_error) result list
(** Diagnostic listing that retains malformed expiry and read/decode failures.
    Invalid records are never returned as authentication credentials. Redirect
    aliases are de-duplicated by the resolved record or failing target. *)

val credential_listing_error_to_string : credential_listing_error -> string

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

type rotation_publication =
  | Published
  | Not_published
  | Publication_unreadable of masc_error

type rotation_failure = {
  error : masc_error;
  raw_token : rotation_publication;
  credential : rotation_publication;
}
(** Observed publication after a per-agent write failure. Files may have changed
    before the failure. Unreadable state is retained rather than guessed. *)

type rotation_outcome = {
  token_hash_prefix : string;
  rotated_agents : (string * (unit, rotation_failure) result) list;
}

val rotation_failure_to_string : rotation_failure -> string

val rotate_shared_tokens : string -> (rotation_outcome list, masc_error) result
(** Read the current canonical credentials and rotate shared groups under one
    Auth transaction. Admission or discovery I/O failure returns [Error] before
    any rotation. Per-agent publication failures remain in the group's results;
    a successful agent has both its credential and recoverable raw token written.
    Rotation forces consumers to fetch their current bearer again. *)

val rotate_shared_tokens_for_agents :
  string -> agent_names:string list -> (rotation_outcome list, masc_error) result
(** Only the selected canonical names participate in groups. The current role
    and identity are preserved while publishers, revoke and prune are excluded
    by the same transaction. *)

val find_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result

val find_static_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result
(** Static bearer-only lookup for the OAuth authorization bootstrap. *)

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
    raw token and persists the credential. Externally supplied tokens are
    opaque and byte-preserving, but empty or whitespace-only input is rejected. *)

val save_raw_token_credential_without_expiry :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result
(** [save_raw_token_credential_without_expiry config ~agent_name ~role
    ~raw_token] persists a credential with [expires_at = None].  Use this for
    local MCP client bearers backed by private token files, not for
    operator-issued session tokens. *)

val save_file_backed_raw_token_credential :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result
(** [save_file_backed_raw_token_credential config ~agent_name ~role
    ~raw_token] persists both the hashed credential and its private raw token
    file under one credential transaction. Refuses unreadable current ownership
    before writes and reports observed partial publication on write failure.
    Rejects whitespace and ASCII control bytes before effects; accepted bearer
    bytes are not normalized. Direct raw-token APIs are unchanged.
    Use only for local operator credentials whose bearer must remain available
    to file-based clients after process restart. *)

type file_backed_token_lifetime = Config_expiry | No_expiry | Expires_in_hours of int

type login_auth_change = Auth_already_required | Auth_enabled | Require_token_enabled

val create_file_backed_login_token :
  string -> agent_name:string -> role:agent_role -> lifetime:file_backed_token_lifetime ->
  (string * agent_credential * login_auth_change, masc_error) result
(** Admit current target ownership before login bootstrap config and credential
    effects; enable required bearer auth and publish both files under one
    transaction, using the explicit lifetime. Player login is refused before
    effects. Errors report partial publication; bootstrap config changes may
    survive failure. This operation does not promise crash rollback. *)

val load_raw_token : string -> agent_name:string -> string option
(** [load_raw_token base_path ~agent_name] reads the raw bearer token from
    [<base_path>/.masc/auth/<agent_name>.token] if present. Returns [None] if
    the file is missing, nonregular, blank, or unreadable. Symlinks to regular
    files are accepted; cancellation propagates. A nonblank opaque token retains
    its exact bytes, including surrounding whitespace. Runtime subprocesses
    use it when they do not inherit the parent's [MASC_TOKEN] environment. *)

val verify_internal_keeper_token :
  string -> token:string -> bool
(** Missing, blank, nonregular or unreadable stored hashes fail verification.
    Symlinks to regular files are accepted and cancellation propagates. *)

val ensure_internal_keeper_token :
  string -> string

val ensure_keeper_credentials :
  string -> agent_names:string list ->
  ((string * (string * agent_credential, masc_error) result) list, masc_error) result
(** Batch startup sync under one admitted token index. Every publisher validates
    current named-owner and UUID authority before writing. After a failure,
    authority is reread before any later independent Keeper is synchronized. *)

val ensure_keeper_credential :
  string -> agent_name:string ->
  (string * agent_credential, masc_error) result
(** [ensure_keeper_credential config ~agent_name] returns a valid credential,
    backed by a per-keeper raw bearer token file. Current ownership, raw-token
    reads, reuse or recreation, and publication share one transaction. True
    absence permits recreation; unreadable or foreign ownership does not.
    Readable stale raw tokens are replaced using the existing Keeper policy.
    A matching pair with whitespace or ASCII control bytes refuses reuse before
    effects; it is not silently normalized or replaced.
    Errors describe observed partial publication when a write fails. The internal
    keeper MCP token remains separate and is only used for the
    [x-masc-internal-token] trust path. Existing names must resolve to this
    exact canonical owner, and UUID ownership is validated before publication. *)

type credential_status =
  | Credential_present of agent_credential
  | Credential_missing

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

val create_token_expiring_in :
  string -> agent_name:string -> role:agent_role -> hours:int ->
  (string * agent_credential, masc_error) result
(** [create_token_expiring_in config ~agent_name ~role ~hours] returns a fresh
    raw token whose credential expires [hours] from now. Use it for a client
    that outlives the workspace's operator-session window but should still lose
    its bearer eventually. A window outside 1..8760 hours comes back as an
    error rather than an exception. *)

type create_token_error =
  | Credential_name_taken
  | Credential_not_created of masc_error

val create_token_expiring_in_if_absent :
  string -> agent_name:string -> role:agent_role -> hours:int ->
  (string * agent_credential, create_token_error) result
(** Create only: check the name file, publish and invalidate the token cache
    in one credential transaction. Existing names, including unreadable files,
    are refused without overwriting them. *)

val verify_token :
  string -> agent_name:string -> token:string ->
  (agent_credential, masc_error) result

(** {1 Permission Checks} *)

val check_permission :
  string -> agent_name:string -> token:string option ->
  permission:permission -> (unit, masc_error) result

val is_tool_auth_strict_enabled : unit -> bool

val authorize_tool :
  string -> agent_name:string -> token:string option ->
  tool_name:string -> (unit, masc_error) result
(** Enforce the exact required permission declared by the registered tool
    catalog. Unregistered names fail closed; prefixes grant no authority. *)

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
(** Pure role check against the same catalog-owned per-tool permission. *)

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
    [cached_hash] is [None]; that fallback fails closed on a nonregular file
    or expected read error. Symlinks to regular files are accepted, and
    cancellation propagates. *)

(** {1 Auth Toggle} *)

val enable_auth :
  string -> require_token:bool -> agent_name:string ->
  string * string option
(** [enable_auth config ~require_token ~agent_name] returns
    [(workspace_secret, bootstrap_token)]. *)

val disable_auth : string -> unit

val is_auth_enabled : string -> bool

val read_initial_admin : string -> string option
(** [read_initial_admin config] returns the bootstrap admin agent name.
    Missing, nonregular, unreadable or blank files yield [None]. Cancellation
    propagates; symlinks to regular files are accepted. *)
