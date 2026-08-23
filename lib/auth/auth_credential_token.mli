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

val check_credential_collisions :
  token_hash_prefix:string -> agent_credential -> agent_credential list -> (unit, masc_error) result

val find_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result

val find_static_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result
(** Static bearer-only lookup. OAuth bootstrap uses this entrypoint so an
    OAuth access token cannot mint a new OAuth grant recursively. General
    request authentication should use {!find_credential_by_token}. *)

val resolve_agent_from_token :
  string -> token:string -> (string, masc_error) result

(** {1 Raw token credential persistence} *)

val save_raw_token_credential :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result

val save_raw_token_credential_without_expiry :
  string -> agent_name:string -> role:agent_role -> raw_token:string ->
  (agent_credential, masc_error) result

(** {1 Token lifecycle} *)

val create_token :
  string -> agent_name:string -> role:agent_role ->
  (string * agent_credential, masc_error) result

val create_token_without_expiry :
  string -> agent_name:string -> role:agent_role ->
  (string * agent_credential, masc_error) result

(** {1 Shared-token rotation} *)

type rotation_outcome = {
  token_hash_prefix : string;
  rotated_agents : (string * (unit, masc_error) result) list;
}

val rotate_shared_tokens : string -> rotation_outcome list

val rotate_shared_tokens_for_agents :
  string -> agent_names:string list -> rotation_outcome list

(** {1 Bearer-token mismatch helpers} *)

val verify_token_owner_alias :
  string -> agent_name:string -> token:string -> (agent_credential, masc_error) result

val verify_token :
  string -> agent_name:string -> token:string -> (agent_credential, masc_error) result
