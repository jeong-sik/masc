open Keeper_types

val managed_kind : string

val turn_kind : string

val all_kind : string

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

val playground_repos_json :
  config:Coord.config ->
  meta:keeper_meta ->
  Yojson.Safe.t

val live_status_json :
  ?include_preflight:bool ->
  ?preflight_override:Yojson.Safe.t option ->
  config:Coord.config ->
  meta:keeper_meta ->
  timeout_sec:float ->
  verbose:bool ->
  unit ->
  Yojson.Safe.t
(** [preflight_override] lets a fleet caller reuse a single Docker
    preflight probe across many keepers; when set (even to [None]),
    the per-keeper render skips its own [docker_preflight] call.
    Pass [Some json] for the cached result, or [None] for "preflight
    was attempted but yielded nothing".  Without this override the
    render falls back to its own preflight invocation. *)

val preflight_status_json :
  timeout_sec:float -> Yojson.Safe.t option
(** Run the global Docker preflight once and return its JSON
    representation, or [None] when no preflight result is available.
    Exposed so fleet renderers can run it a single time and feed the
    cached value into many [live_status_json] calls instead of
    repeating the expensive Docker probe per keeper. *)
