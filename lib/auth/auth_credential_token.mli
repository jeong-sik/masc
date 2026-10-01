(** Token operations for MASC authentication.

    This module is included by {!Auth} to provide token lookup, creation,
    verification, and shared-token rotation. The public surface is mirrored
    in {!Auth}; this interface exists to satisfy the library's structural
    mli-coverage ratchet. *)

open Masc_domain

(** {1 Credential comparison} *)

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

val constant_time_string_equal : string -> string -> bool
(** Timing-resistant equality provided by {!Eqaf.equal}. Execution time
    depends on the input lengths, not their contents. Auth callers compare
    fixed-width SHA-256 hex digests. *)

val compare_credentials :
  token_hash_prefix:string -> agent_credential -> agent_credential -> credential_comparison

(** {1 Token lookup} *)

val find_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result

val find_static_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result
(** Static bearer-only lookup. OAuth bootstrap uses this entrypoint so an
    OAuth access token cannot mint a new OAuth grant recursively. General
    request authentication should use {!find_credential_by_token}. Static
    candidates must match the complete current named credential, including
    after a cache rebuild; standalone UUID payloads are data, not independent
    bearer authority. *)

val find_static_credential_in_index :
  (string, agent_credential list) Hashtbl.t -> token:string ->
  (agent_credential, masc_error) result
(** Only for an index owned by the caller's admitted transaction. *)

val find_static_credential_in_transaction :
  ?leaf_policy:Auth_credential_base.credential_leaf_policy ->
  Auth_credential_base.credential_transaction -> token:string ->
  (agent_credential, masc_error) result
(** Reads all current owners under the caller's transaction, without consulting
    the request cache or acquiring the transaction again. *)

val resolve_agent_from_token :
  string -> token:string -> (string, masc_error) result

(** {1 Raw token credential persistence} *)

val save_raw_token_credential :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result

val save_raw_token_credential_without_expiry :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result

val save_file_backed_raw_token_credential :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result

type file_backed_token_lifetime = Config_expiry | No_expiry | Expires_in_hours of int

type login_auth_change = Auth_already_required | Auth_enabled | Require_token_enabled

val create_file_backed_login_token :
  string -> agent_name:string -> role:agent_role -> lifetime:file_backed_token_lifetime ->
  (string * agent_credential * login_auth_change, masc_error) result
(** Admit current target ownership before login bootstrap config and credential
    effects; enable required bearer auth and publish both files in one admitted
    transaction. Player login is refused before effects. Errors describe partial
    publication; bootstrap config changes may survive failure, without rollback. *)

(** {1 Token lifecycle} *)

val create_token :
  string -> agent_name:string -> role:agent_role ->
  (string * agent_credential, masc_error) result

val create_token_without_expiry :
  string -> agent_name:string -> role:agent_role ->
  (string * agent_credential, masc_error) result

val create_token_expiring_in :
  string -> agent_name:string -> role:agent_role -> hours:int ->
  (string * agent_credential, masc_error) result
(** [create_token_expiring_in config ~agent_name ~role ~hours] returns a fresh
    raw token whose credential expires [hours] from now, ignoring the auth
    config's own window. Rejects a window outside 1..8760 hours rather than
    raising, so a caller that computes the number can report the refusal. *)

(** {1 Shared-token rotation} *)

type create_token_error =
  | Credential_name_taken
  | Credential_not_created of masc_error

val create_token_expiring_in_if_absent :
  string -> agent_name:string -> role:agent_role -> hours:int ->
  (string * agent_credential, create_token_error) result
(** Check name-file absence and publish under the same credential transaction.
    Existing names are refused even when their credential cannot be read. *)

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
(** Shared groups are discovered globally; only selected canonical owners are rotated. The current role
    and identity are preserved while publishers, revoke and prune are excluded
    by the same transaction. *)

(** {1 Bearer-token mismatch helpers} *)

val verify_token_owner_alias :
  string -> agent_name:string -> token:string -> (agent_credential, masc_error) result

val verify_token :
  string -> agent_name:string -> token:string -> (agent_credential, masc_error) result
(** Static verification through a UUID or stored redirect alias requires the
    complete credential to still match its owner's current named binding.
    Direct UUID data reads do not grant independent bearer authority. *)
