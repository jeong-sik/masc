(** Credential storage and auth config helpers. *)

open Masc_domain

val generate_token : unit -> string
val sha256_hash : string -> string

val auth_dir : string -> string
val agents_dir : string -> string
val workspace_secret_file : string -> string
val auth_config_file : string -> string
val initial_admin_file : string -> string
val internal_keeper_token_hash_file : string -> string
val internal_keeper_token_env_key : string

val file_exists : string -> bool
val read_text_file : string -> string
val write_text_file : string -> string -> unit
val chmod : string -> int -> unit
val read_dir : string -> string array
val remove_file : string -> unit

val ensure_auth_dirs : string -> unit
val write_initial_admin : string -> string -> unit
val save_private_text_file : string -> string -> unit

val verify_internal_keeper_token : string -> token:string -> bool
val ensure_internal_keeper_token : string -> string
val read_initial_admin : string -> string option

val persist_auth_config : string -> auth_config -> unit
val load_auth_config : string -> auth_config
val save_auth_config : string -> auth_config -> unit

val credential_file : string -> string -> string
val is_generated_nickname_shape : string -> bool
val keeper_transport_alias_stable_name : string -> string option
val extract_agent_type_prefix : string -> string option
val credential_agent_name : string -> string

val load_redirect_target : string -> string -> string option
val load_credential : string -> string -> agent_credential option

type load_credential_error =
  | Credential_missing of { ctx_agent_name : string }
  | Credential_mismatch of
      { ctx_agent_name : string
      ; resolved_credential_stem : string
      }

val pp_load_credential_error :
  Format.formatter -> load_credential_error -> unit

val show_load_credential_error : load_credential_error -> string

val load_credential_of :
  string ->
  ctx_agent_name:string ->
  resolved_credential_stem:string ->
  (agent_credential, load_credential_error) result

val save_credential : string -> agent_credential -> unit

val ensure_credential_alias :
  string ->
  canonical_name:string ->
  alias_name:string ->
  (unit, masc_error) result

val load_raw_token : string -> agent_name:string -> string option
val persist_raw_token : string -> agent_name:string -> string -> unit
val delete_credential : string -> string -> unit
val list_credentials : string -> agent_credential list

val invalidate_credential_index_cache : string -> unit

val credential_token_index :
  string -> (string, agent_credential list) Hashtbl.t

val group_credentials_by_token : string -> (string * agent_credential list) list
val token_hash_prefix_of : string -> string
val audit_token_uniqueness : string -> (string * string list) list
