(** Token operations for MASC authentication. *)

open Masc_domain

val find_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result

val resolve_agent_from_token :
  string -> token:string -> (string, masc_error) result

val save_raw_token_credential :
  string ->
  agent_name:string ->
  role:agent_role ->
  raw_token:string ->
  (agent_credential, masc_error) result

val save_raw_token_credential_without_expiry :
  string ->
  agent_name:string ->
  role:agent_role ->
  raw_token:string ->
  (agent_credential, masc_error) result

val create_token :
  string ->
  agent_name:string ->
  role:agent_role ->
  (string * agent_credential, masc_error) result

val create_token_without_expiry :
  string ->
  agent_name:string ->
  role:agent_role ->
  (string * agent_credential, masc_error) result

type rotation_outcome =
  { token_hash_prefix : string
  ; rotated_agents : (string * (unit, masc_error) result) list
  }

val rotate_shared_tokens : string -> rotation_outcome list

val rotate_shared_tokens_for_agents :
  string -> agent_names:string list -> rotation_outcome list

val verify_token :
  string ->
  agent_name:string ->
  token:string ->
  (agent_credential, masc_error) result
