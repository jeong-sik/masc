open Keeper_types

val effective_sandbox_profile :
  meta:keeper_meta ->
  in_playground:bool ->
  sandbox_profile * network_mode

val optional_ro_mount :
  host:string -> container:string -> string list
