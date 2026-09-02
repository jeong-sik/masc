(** The remote lane's endpoint for a keeper, by profile. *)

val endpoint :
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  unit ->
  (Keeper_sandbox_remote.t, string) result
(** Remote_ssh: the runtime.toml endpoint, created and (when preflight is
    enabled) checked. Micro_vm: the turn factory's running guest, started if
    it is not up; without a factory the call is refused
    ([microvm_remote_requires_turn_sandbox_factory]). Docker: refused
    ([docker_has_no_remote_lane]). *)

val remote_root :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (string, string) result
(** The endpoint's root for path translation, without reaching the endpoint:
    the registry entry's [remote_root] for Remote_ssh, the work volume's guest
    mount for Micro_vm. *)
