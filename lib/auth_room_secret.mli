(** Room secret and high-level auth toggle helpers. *)

open Masc_domain

val init_room_secret : string -> string
val verify_room_secret : string -> string -> bool

val enable_auth
  :  create_token:
       (string
        -> agent_name:string
        -> role:agent_role
        -> (string * agent_credential, masc_error) result)
  -> string
  -> require_token:bool
  -> agent_name:string
  -> string * string option

val disable_auth : string -> unit
val is_auth_enabled : string -> bool
