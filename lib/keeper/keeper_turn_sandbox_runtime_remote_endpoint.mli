(** The remote endpoint a microvm guest is reached through: the check that a
    keeper runs a microvm profile, and the builder of the endpoint. The
    backend decides the delivery ({!Keeper_microvm_backend.request_delivery}):
    the agent socket of an Apple guest, or the shim exec prefix of the other
    runtimes.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_meta_contract

val microvm_profile_check :
  keeper_meta -> (unit, string) result

val build_microvm_endpoint :
  config:Workspace_utils_backend_setup.config ->
  meta:keeper_meta ->
  container_root:string ->
  uid:int ->
  gid:int ->
  container_name:string ->
  identity_environment:(string * string) list ->
  (Keeper_sandbox_remote.t, string) result
