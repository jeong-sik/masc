open Keeper_types

val managed_kind : string

val turn_kind : string

type stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

val parse_stop_scope : string -> (stop_scope, string) result

val stop_scope_to_string : stop_scope -> string

val start_managed_container :
  config:Coord.config ->
  meta:keeper_meta ->
  network_mode:network_mode ->
  ttl_sec:float ->
  timeout_sec:float ->
  unit ->
  (Yojson.Safe.t, string) result

val stop_managed_containers :
  ?keeper_name:string ->
  config:Coord.config ->
  timeout_sec:float ->
  unit ->
  Keeper_sandbox_runtime.stop_result

val stop_containers :
  ?keeper_name:string ->
  scope:stop_scope ->
  config:Coord.config ->
  timeout_sec:float ->
  unit ->
  Keeper_sandbox_runtime.stop_result

val cleanup_stale :
  config:Coord.config ->
  timeout_sec:float ->
  unit ->
  Keeper_sandbox_runtime.cleanup_result

val live_status_json :
  ?include_preflight:bool ->
  config:Coord.config ->
  meta:keeper_meta ->
  timeout_sec:float ->
  verbose:bool ->
  unit ->
  Yojson.Safe.t
