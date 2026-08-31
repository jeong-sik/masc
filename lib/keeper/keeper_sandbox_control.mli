open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val managed_kind : string

val turn_kind : string


type stop_scope = Keeper_sandbox_control_contract.stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

val parse_stop_scope : string -> (stop_scope, string) result

val stop_scope_to_string : stop_scope -> string

val start_managed_container :
  config:Workspace.config ->
  meta:keeper_meta ->
  network_mode:network_mode ->
  ttl_sec:float ->
  timeout_sec:float ->
  unit ->
  (Yojson.Safe.t, string) result

val stop_containers :
  ?keeper_name:string ->
  scope:stop_scope ->
  config:Workspace.config ->
  timeout_sec:float ->
  unit ->
  Keeper_sandbox_runtime.stop_result

val repository_checkouts_json :
  config:Workspace.config ->
  meta:keeper_meta ->
  Yojson.Safe.t
(** Inspect Keeper-visible repository checkouts. Repository identity comes
    from the repository catalog; execution availability comes from the
    checkout directory; freshness is measured against the local tracking ref.
    Missing or ambiguous evidence is returned as an explicit typed state. *)

module For_testing : sig
  val repository_checkouts_json_with_budget :
    inspection_budget_sec:float ->
    config:Workspace.config ->
    meta:keeper_meta ->
    Yojson.Safe.t

  val repository_checkouts_json_with_budget_after_discovery :
    before_git_inspection:(unit -> unit) ->
    inspection_budget_sec:float ->
    config:Workspace.config ->
    meta:keeper_meta ->
    Yojson.Safe.t
end

val live_status_json :
  ?include_preflight:bool ->
  ?preflight_override:Keeper_sandbox_runtime.docker_preflight option ->
  ?containers_override:(Keeper_sandbox_runtime.live_container list, string) result ->
  ?include_repository_checkouts:bool ->
  config:Workspace.config ->
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
    render falls back to its own preflight invocation.

    [containers_override] lets a fleet caller reuse one base-path-scoped
    Docker listing and filter it by keeper in memory.  Without it the
    render performs its own keeper-scoped Docker listing.

    [include_repository_checkouts=false] skips Git checkout inspection for
    dashboard hot paths. *)

