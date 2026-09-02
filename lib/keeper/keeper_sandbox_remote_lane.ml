(** The remote lane's endpoint for a keeper, by profile.

    An OpenSSH keeper names its endpoint in runtime.toml; a microvm keeper's
    endpoint is its running guest, which only the turn's sandbox factory
    knows. A Docker keeper has no remote lane: its tree is a shared mount.
    The two remote profiles differ only in how the endpoint is found; what
    it is once found ([Keeper_sandbox_remote.t]) is the same. *)

open Keeper_meta_contract

let ( let* ) = Result.bind

let docker_has_no_remote_lane (meta : keeper_meta) =
  Printf.sprintf
    "docker_has_no_remote_lane: keeper %s runs sandbox_profile=docker, whose tree is a shared mount; there is no endpoint to reach"
    meta.name
;;

(* The same readiness check for both transports: the probe is cached per
   endpoint name, so a running guest pays it once, like an OpenSSH host. *)
let ready endpoint =
  let* () =
    if Env_config_sandbox.Preflight.enabled ()
    then Keeper_sandbox_remote.check_preflight endpoint
    else Ok ()
  in
  Ok endpoint
;;

let openssh_endpoint ~(config : Workspace.config) ~(meta : keeper_meta) =
  let* endpoint =
    Keeper_sandbox_ssh.resolve_endpoint
      ~base_path:config.base_path ~keeper_name:meta.name
  in
  let* ssh =
    Keeper_sandbox_ssh.create ~base_path:config.base_path
      ~keeper_name:meta.name ~endpoint ()
  in
  ready ssh
;;

let microvm_endpoint ?timeout_sec runtime =
  let* guest = Keeper_turn_sandbox_runtime.microvm_remote_endpoint ?timeout_sec runtime in
  ready guest
;;

let profile_contract_mismatch ~expected ~actual =
  Printf.sprintf
    "sandbox profile contract mismatch: caller expected %s but the turn factory froze %s"
    (Keeper_types_profile_sandbox.sandbox_profile_to_string expected)
    (Keeper_types_profile_sandbox.sandbox_profile_to_string actual)
;;

let guest_endpoint ~turn_sandbox_factory ~(meta : keeper_meta) ~cwd =
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | Keeper_sandbox_factory.Runtime { runtime; guest_profile = Micro_vm_guest; _ } ->
    microvm_endpoint runtime
  | Keeper_sandbox_factory.Runtime { guest_profile = Docker_guest; _ } ->
    Error (profile_contract_mismatch ~expected:meta.sandbox_profile ~actual:Docker)
  | Keeper_sandbox_factory.Remote_ssh_profile ->
    Error (profile_contract_mismatch ~expected:meta.sandbox_profile ~actual:Remote_ssh)
  | Keeper_sandbox_factory.No_factory ->
    Error
      (Printf.sprintf
         "microvm_remote_requires_turn_sandbox_factory: keeper %s's guest is known only to the turn's sandbox factory, and this call has none"
         meta.name)
;;

let endpoint ?turn_sandbox_factory ~(config : Workspace.config) ~(meta : keeper_meta) ~cwd () =
  match meta.sandbox_profile with
  | Docker -> Error (docker_has_no_remote_lane meta)
  | Remote_ssh -> openssh_endpoint ~config ~meta
  | Micro_vm -> guest_endpoint ~turn_sandbox_factory ~meta ~cwd
;;

(* The remote root is a config fact for OpenSSH and a constant for a guest,
   so a path can be translated before, or without, reaching the endpoint. *)
let remote_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker -> Error (docker_has_no_remote_lane meta)
  | Remote_ssh ->
    let* endpoint =
      Keeper_sandbox_ssh.resolve_endpoint
        ~base_path:config.base_path ~keeper_name:meta.name
    in
    Ok endpoint.remote_root
  | Micro_vm -> Ok Keeper_sandbox_microvm.work_volume_guest_root
;;
