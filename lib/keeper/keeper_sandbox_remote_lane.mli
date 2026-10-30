(** The remote lane's endpoint for a keeper, by profile. *)

type read_authority
(** One attached endpoint and its declared path authority, captured together.
    It starts no guest and cannot select a replacement endpoint on dispatch. *)

val capture_read_authority :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> unit ->
  (read_authority option, string) result
(** [None] for a shared Docker tree. SSH captures the actual typed declaration.
    Apple captures a route and host snapshot without observing the guest;
    guest use must go through {!with_read_authority_endpoint}. Other MicroVMs
    capture the attached endpoint without booting it. *)

val with_read_authority_endpoint :
  ?timeout_sec:float -> read_authority -> config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  (Keeper_sandbox_remote.t -> ('a, string) result) -> ('a, string) result
(** Use the captured endpoint within the callback. Check the owning
    workspace, Keeper, profile and captured microVM backend/network. Apple
    additionally checks observed ownership labels, the host-side credential
    snapshot revision and the route under the process-local Keeper lifecycle
    owner, then releases that owner before the callback. A captured microVM
    also reconciles the host shim config before dispatch; this neither selects
    another endpoint nor proves that the guest can read its mount. The Apple
    check does not prove the observed guest's mounted inode. The timeout bounds the Apple inspect,
    not the entire call. SSH keeps the captured endpoint without reading
    current configuration. Any process may replace a guest between inspection
    and use. *)

val read_authority_identity : read_authority -> Yojson.Safe.t
(** The existing durable projection. It does not bind the Apple host snapshot
    revision; a reconstructed authority may have the same identity after that
    revision changes. *)
val read_authority_route : read_authority -> Yojson.Safe.t
(** Configuration route of this same captured endpoint, in the Task review's
    route vocabulary. The host compares current configuration with this value;
    it must not recapture a different route after acquiring the endpoint. *)
val apple_snapshot_route :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> (Yojson.Safe.t, string) result
(** Observe the host snapshot and route without observing or executing the guest. *)
val read_authority_workspace_root : read_authority -> string
val read_authority_declared_path : read_authority -> string -> string option
val read_authority_declared_path_of_args :
  read_authority -> path:string -> cwd:string option -> string option

val microvm_endpoint :
  ?timeout_sec:float ->
  Keeper_turn_sandbox_runtime.t ->
  (Keeper_sandbox_remote.t, string) result
(** The turn runtime's guest as an endpoint, started if it is not up. No
    preflight: that is the OpenSSH bootstrap contract, and its [gh auth
    status] step cannot pass in a guest whose network is closed or whose
    keeper has no GitHub login; the boot establishes what a guest needs. The
    Execute target for a microvm keeper acquires its endpoint through this on
    each call, so a guest that went away between calls is booted again rather
    than reported dead. *)

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
    ([microvm_remote_requires_turn_sandbox_factory]) because starting the
    guest belongs to the turn that owns it -- which a write to a stopped
    guest needs. A caller that only needs a guest already running takes
    {!attached_guest_endpoint}. Docker: refused
    ([docker_has_no_remote_lane]). *)

val attached_guest_endpoint :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (Keeper_sandbox_remote.t, string) result
(** The endpoint for a caller that owns no turn. Micro_vm: the guest named by
    the keeper and the base path, reached without starting it -- so a read
    from outside the keeper cannot spend a VM boot or write the identity
    snapshot and work root that a boot creates. Remote_ssh: the same endpoint
    {!endpoint} returns, since finding it never needed a turn. Docker:
    refused, as there is no endpoint to reach.

    Use {!endpoint} from inside a turn: a turn owns the guest's lifecycle and
    is entitled to start it, which a write to a stopped guest requires. *)

val endpoint_root :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (string, string) result
(** The endpoint-wide root, without reaching the endpoint: the registry
    entry's [remote_root] for Remote_ssh, the work volume's guest mount for
    Micro_vm. *)

val workspace_root :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (string, string) result
(** The resolved workspace used for path translation:
    [<endpoint_root>/<sanitized keeper name>]. *)

val declared_path_of_endpoint : Exec_ssh_endpoint.t -> string -> string option
(** [Some p] when [path] is absolute and under one of [endpoint]'s declared
    roots ([allowed_paths], {!Exec_policy_paths.extra_root_path}); [p] is the
    endpoint path, lexically normalized. The one judgment {!declared_endpoint_path}
    and the remote Write lane both make. *)

val declared_endpoint_path :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  string ->
  (string option, string) result
(** [Ok (Some p)] when an OpenSSH keeper names an absolute path that lies
    under one of its endpoint's declared roots ([allowed_paths],
    {!Exec_policy_paths.extra_root_path}); [p] is the endpoint path,
    lexically normalized, to read as itself. [Ok None] for a relative path, a
    path under no declared root, and every Docker or Micro_vm keeper (neither
    declares roots). [Error] when the keeper's endpoint cannot be resolved.

    It does not look at the keeper's own host bookkeeping tree. Ask it only
    for a path that tree refused: a name the tree accepts must keep meaning
    the keeper's own file, whatever a declared root's spelling covers. *)

val declared_endpoint_path_of_args :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  path:string ->
  cwd:string option ->
  (string option, string) result
(** {!declared_endpoint_path} of what a file tool's [path] and [cwd] name
    together: an absolute [path] as itself, a relative [path] under an
    absolute [cwd] joined to it. A relative [path] with no [cwd] or a
    relative one is a name in the keeper's tree and is [Ok None]. *)

val is_guest_booted :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  bool
(** Pure in-memory query: whether the remote endpoint is booted/ready in this process.
    True for Remote_ssh, false for Docker, and reflects the booted state for Micro_vm. *)
