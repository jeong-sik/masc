(** Tool authorization helpers used by [Auth].

    This module keeps tool-name classification and strict-mode policy out of
    the credential/token store while accepting [check_permission] as a callback
    to avoid an [Auth] dependency cycle. *)

open Masc_domain

val permission_for_tool : string -> permission option

val is_tool_auth_strict_enabled : unit -> bool

val authorize_tool
  :  check_permission:
       (string
        -> agent_name:string
        -> token:string option
        -> permission:permission
        -> (unit, masc_error) result)
  -> string
  -> agent_name:string
  -> token:string option
  -> tool_name:string
  -> (unit, masc_error) result

val authorize_tool_for_role
  :  agent_name:string
  -> role:agent_role
  -> tool_name:string
  -> (unit, masc_error) result
