open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type stop_scope = Keeper_types_profile_sandbox.sandbox_stop_scope =
  | Stop_kind of Keeper_types_profile_sandbox.sandbox_container_kind
  | Stop_all

val parse_stop_scope : string -> (stop_scope, string) result

val stop_scope_to_string : stop_scope -> string

val stop_containers :
  ?keeper_name:string ->
  scope:stop_scope ->
  config:Workspace.config ->
  timeout_sec:float ->
  unit ->
  Keeper_sandbox_runtime.stop_result

type playground_policy_status =
  | Policy_allowed
  | Policy_unregistered_repository
  | Policy_mapping_load_error
  | Policy_repository_identity_mismatch
  | Policy_repository_store_error

val playground_policy_status_to_string : playground_policy_status -> string
(** Wire-format label for the playground repo policy status.  Exposed so
    tests and callers can assert against the same strings the JSON response
    uses without duplicating them. *)

val policy_source_basename_of_status : playground_policy_status -> string
(** Basename of the config file that actually decided a status: the repository
    catalog ([repositories.toml]) for every allow/deny verdict, since that is
    the binding gate, and the advisory mapping ([keeper_repo_mappings.toml])
    only for its own load failure (RFC-0312). Exposed so the [policy_source]
    field's source-of-truth is asserted against the same mapping the JSON uses,
    rather than a hardcoded basename that misreported catalog denials as
    mapping denials. *)

val playground_repos_json :
  timeout_sec:float ->
  config:Workspace.config ->
  meta:keeper_meta ->
  Yojson.Safe.t

val live_status_json :
  ?include_preflight:bool ->
  ?preflight_override:Keeper_sandbox_runtime.docker_preflight option ->
  ?containers_override:(Keeper_sandbox_runtime.live_container list, string) result ->
  ?include_playground_repos:bool ->
  config:Workspace.config ->
  meta:keeper_meta ->
  timeout_sec:float ->
  verbose:bool ->
  unit ->
  Yojson.Safe.t
(** [preflight_override] lets a fleet caller reuse a single Docker
    preflight probe across many keepers; when set (even to [None]),
    the per-keeper render skips its own [docker_preflight] call.
    Pass [Some status] for the cached typed result, or [None] for "preflight
    was attempted but yielded nothing".  Without this override the
    render falls back to its own preflight invocation.

    [containers_override] lets a fleet caller reuse one base-path-scoped
    Docker listing and filter it by keeper in memory.  Without it the
    render performs its own keeper-scoped Docker listing.

    [include_playground_repos=false] skips live playground repo enrichment,
    including per-repo Git metadata probes, for dashboard hot paths.

    The response includes a typed [security_boundary] projection. Local mode is
    reported as a host process with tool-policy filesystem scope and managed
    HOME credentials; Docker mode reports explicit mounts, effective network
    namespace, rootfs mode, capability drop, and no-new-privileges truth. *)

val preflight_status :
  timeout_sec:float -> Keeper_sandbox_runtime.docker_preflight option
(** Run the global Docker preflight once and keep it typed until the JSON
    response boundary. Fleet renderers reuse this value without reparsing an
    internal JSON projection. *)
