(** The remote lane's endpoint for a keeper, by profile.

    An OpenSSH keeper names its endpoint in runtime.toml; a microvm keeper's
    endpoint is its running guest, which only the turn's sandbox factory
    knows. A Docker keeper has no remote lane: its tree is a shared mount.
    The two remote profiles differ only in how the endpoint is found; what
    it is once found ([Keeper_sandbox_remote.t]) is the same. *)

open Keeper_meta_contract

open Result.Syntax

let docker_has_no_remote_lane (meta : keeper_meta) =
  Printf.sprintf
    "docker_has_no_remote_lane: keeper %s runs sandbox_profile=docker, whose tree is a shared mount; there is no endpoint to reach"
    meta.name
;;

(* The preflight is the OpenSSH bootstrap contract: a host the operator
   provisioned, reachable over the network, holding a GitHub identity the
   bootstrap installed. It stays with that transport. *)
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

(* No preflight for a guest. The runtime that boots it establishes what the
   preflight would ask of an OpenSSH host -- the image, the shim mount, the
   work volume, the keeper's root on it, the identity snapshot -- and the
   preflight's last step is [gh auth status], which a guest whose profile
   closes its network ([Network_none]) or whose keeper has no GitHub login
   cannot pass. Running it here refused every Execute, Read, Write and Edit
   of such a keeper, on a lane the Docker container never gated on identity. *)
let microvm_endpoint ?timeout_sec runtime =
  Keeper_turn_sandbox_runtime.microvm_remote_endpoint ?timeout_sec runtime
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
         "microvm_remote_requires_turn_sandbox_factory: keeper %s's guest may have to be started to serve this call, and only the turn that owns its lifecycle may start it. A read that only needs a running guest takes attached_guest_endpoint instead"
         meta.name)
;;

(* The turn-free door to the same guest. [endpoint] above finds the guest
   through the turn that owns its lifecycle and may start it; this one names
   the guest directly and cannot start anything. A caller with no turn --
   verification lookup, an operator surface -- reads through this and gets a
   refusal only when the guest is genuinely down. *)
let attached_guest_endpoint ?timeout_sec ~(config : Workspace.config) ~(meta : keeper_meta) () =
  match meta.sandbox_profile with
  | Docker -> Error (docker_has_no_remote_lane meta)
  | Remote_ssh -> openssh_endpoint ~config ~meta
  | Micro_vm -> Keeper_turn_sandbox_runtime.microvm_attached_endpoint ?timeout_sec ~config ~meta ()
;;

let endpoint ?turn_sandbox_factory ~(config : Workspace.config) ~(meta : keeper_meta) ~cwd () =
  match meta.sandbox_profile with
  | Docker -> Error (docker_has_no_remote_lane meta)
  | Remote_ssh -> openssh_endpoint ~config ~meta
  | Micro_vm -> guest_endpoint ~turn_sandbox_factory ~meta ~cwd
;;

(* The endpoint root is a config fact for OpenSSH and a constant for a guest,
   so the resolved workspace can be named before, or without, reaching it. *)
let endpoint_root ~(config : Workspace.config) ~(meta : keeper_meta) =
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

let workspace_root ~(config : Workspace.config) ~(meta : keeper_meta) =
  let* root = endpoint_root ~config ~meta in
  Ok (Filename.concat root (Playground_paths.sanitize_keeper_name meta.name))
;;

(* #38593: an OpenSSH endpoint's declared roots ([allowed_paths]) name
   endpoint paths outside the keeper's tree that its commands may use, such
   as a Terminal-Bench task's /app. A file read there names the endpoint's own
   file, so it reaches the endpoint as itself instead of through the host
   bookkeeping namespace. This does not look at the keeper's tree: callers ask
   it only for a path the tree refused, so a name the tree accepts keeps its
   meaning whatever a declared root's spelling covers. *)
let declared_path_of_endpoint (endpoint : Exec_ssh_endpoint.t) path =
  if Filename.is_relative path
  then None
  else Exec_policy_paths.extra_root_path ~extra_roots:endpoint.allowed_paths path
;;

let declared_endpoint_path ~(config : Workspace.config) ~(meta : keeper_meta) path =
  match meta.sandbox_profile with
  | Docker | Micro_vm -> Ok None
  | Remote_ssh ->
    if Filename.is_relative path
    then Ok None
    else
      let* endpoint =
        Keeper_sandbox_ssh.resolve_endpoint
          ~base_path:config.base_path ~keeper_name:meta.name
      in
      Ok (declared_path_of_endpoint endpoint path)
;;

(* A file tool names a path with [path] and an optional [cwd]. Only an
   absolute spelling can be an endpoint path: the path itself, or a relative
   path under an absolute cwd. A relative cwd is a name in the keeper's tree. *)
let declared_endpoint_path_of_args ~config ~meta ~path ~cwd =
  let spelling =
    match Filename.is_relative path, cwd with
    | false, _ -> Some path
    | true, Some cwd when not (Filename.is_relative cwd) -> Some (Filename.concat cwd path)
    | true, (Some _ | None) -> None
  in
  match spelling with
  | None -> Ok None
  | Some spelling -> declared_endpoint_path ~config ~meta spelling
;;

type read_authority = {
  base_path : string;
  keeper : string;
  profile : Keeper_types_profile.sandbox_profile;
  endpoint : Keeper_sandbox_remote.t;
  declaration : Exec_ssh_endpoint.t option;
  microvm_scope : (Keeper_microvm_backend.t option * Keeper_types_profile_sandbox.network_mode) option;
  apple_revision : string option;
}

(* This value can contain environment values. It is compared only in memory. *)
let apple_endpoint_route endpoint =
  let strings values = `List (List.map (fun value -> `String value) values) in
  `Assoc ["name", `String (Keeper_sandbox_remote.name endpoint);
    "workspace_root", `String (Keeper_sandbox_remote.workspace_root endpoint);
    "gh_config_dir", `String (Keeper_sandbox_remote.gh_config_dir endpoint);
    "transport_argv", strings (Keeper_sandbox_remote.transport_argv endpoint);
    "probe_argv", strings (Keeper_sandbox_remote.probe_argv endpoint);
    "injected_env", `List (List.map (fun (key, value) ->
      `List [`String key; `String value]) (Keeper_sandbox_remote.injected_env endpoint))]

let capture_read_authority ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let capture endpoint declaration apple_revision =
    let microvm_scope = match meta.sandbox_profile with
      | Micro_vm -> Some (meta.microvm_backend, meta.network_mode)
      | Docker | Remote_ssh -> None in
    Some {base_path=config.base_path;keeper=meta.name;profile=meta.sandbox_profile;
      endpoint;declaration;microvm_scope;apple_revision} in
  match meta.sandbox_profile with
  | Docker -> Ok None
  | Remote_ssh ->
    let* declaration = Keeper_sandbox_ssh.resolve_endpoint ~base_path:config.base_path ~keeper_name:meta.name in
    let* endpoint = Keeper_sandbox_ssh.create ~base_path:config.base_path ~keeper_name:meta.name ~endpoint:declaration () in
    let* endpoint = ready endpoint in
    Ok (capture endpoint (Some declaration) None)
  | Micro_vm ->
    (match meta.microvm_backend with
     | Some Keeper_microvm_backend.Apple_container ->
       Keeper_turn_sandbox_runtime.with_apple_snapshot_endpoint ~config ~meta
         (fun ~revision endpoint -> Ok (capture endpoint None (Some revision)))
     | None | Some (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
       let* endpoint = attached_guest_endpoint ~config ~meta () in
       Ok (capture endpoint None None))

let with_read_authority_endpoint ?timeout_sec authority ~(config : Workspace.config) ~(meta : keeper_meta) use =
  if not (String.equal authority.base_path config.base_path && String.equal authority.keeper meta.name
          && authority.profile = meta.sandbox_profile)
  then Error "captured read authority belongs to another workspace, Keeper or sandbox profile"
  else if Option.exists (fun scope -> scope <> (meta.microvm_backend, meta.network_mode)) authority.microvm_scope
  then Error "captured read authority microVM backend or network changed"
  else match authority.apple_revision with
    | None -> use authority.endpoint
    | Some expected_revision ->
      let* () = Keeper_turn_sandbox_runtime.with_apple_attached_endpoint ?timeout_sec ~config ~meta (fun ~revision current ->
        let same_route = Yojson.Safe.equal (apple_endpoint_route current)
            (apple_endpoint_route authority.endpoint) in
        if not (String.equal expected_revision revision && same_route)
        then Error "captured Apple read authority credential snapshot or route changed"
        else Ok ()) in
      use authority.endpoint

let read_authority_workspace_root authority = Keeper_sandbox_remote.workspace_root authority.endpoint

let read_authority_identity authority =
  let strings values = `List (List.map (fun value -> `String value) values) in
  `Assoc ["workspace",`String authority.base_path;"keeper",`String authority.keeper;
    "profile",`String (Keeper_types_profile.sandbox_profile_to_string authority.profile);
    "workspace_root",`String (read_authority_workspace_root authority);
    "transport_argv",strings (Keeper_sandbox_remote.transport_argv authority.endpoint);
    "declaration",(match authority.declaration with
      | None -> `Null | Some declaration -> `String (Exec_ssh_endpoint.to_toml declaration))]

let microvm_endpoint_route endpoint =
  `Assoc ["kind", `String "microvm";
    "argv", `List (List.map (fun value -> `String value)
      (Keeper_sandbox_remote.transport_argv endpoint));
    "root", `String (Keeper_sandbox_remote.workspace_root endpoint)]

let apple_snapshot_route ~(config : Workspace.config) ~(meta : keeper_meta) =
  Keeper_turn_sandbox_runtime.with_apple_snapshot_endpoint ~config ~meta
    (fun ~revision:_ endpoint -> Ok (microvm_endpoint_route endpoint))

let read_authority_route authority =
  match authority.declaration with
  | Some declaration ->
    `Assoc ["kind", `String "ssh"; "endpoint", `String (Exec_ssh_endpoint.to_toml declaration)]
  | None -> microvm_endpoint_route authority.endpoint

let read_authority_declared_path authority path = match authority.declaration with
  | None -> None
  | Some declaration -> declared_path_of_endpoint declaration path

let read_authority_declared_path_of_args authority ~path ~cwd =
  match Filename.is_relative path, cwd with
  | false, _ -> read_authority_declared_path authority path
  | true, Some cwd when not (Filename.is_relative cwd) ->
    read_authority_declared_path authority (Filename.concat cwd path)
  | true, (Some _ | None) -> None

let is_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
  match meta.sandbox_profile with
  | Docker -> false
  | Remote_ssh -> true
  | Micro_vm -> Keeper_turn_sandbox_runtime.is_microvm_guest_booted ~config ~meta ()
;;
