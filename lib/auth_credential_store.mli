(** Credential file, redirect, and raw-token persistence helpers. *)

open Masc_domain

val credential_file : string -> string -> string
val load_redirect_target : string -> string -> string option
val legacy_credential_aliases : string -> string list
val load_credential : string -> string -> agent_credential option
val load_credential_with_aliases : string -> string -> agent_credential option
val save_credential : string -> agent_credential -> unit

val ensure_credential_alias
  :  string
  -> canonical_name:string
  -> alias_name:string
  -> (unit, masc_error) result

val load_raw_token : string -> agent_name:string -> string option
val persist_raw_token : string -> agent_name:string -> string -> unit
val delete_credential : string -> string -> unit
val list_credentials : string -> agent_credential list
