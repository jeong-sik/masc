(** Transport-neutral runner for the remote execution lane.

    One endpoint value drives the framed [masc-exec-shim] exchange
    ({!Exec_ssh_protocol}) over either transport. The OpenSSH transport is
    the RFC-0395 lane; the guest-exec transport is the RFC-0400 lane for a
    microVM guest that owns its working tree. *)

type openssh =
  { endpoint : Exec_ssh_endpoint.t
  ; ssh_bin : string
  ; identity_file : string  (** Resolved against the workspace base path. *)
  ; known_hosts_file : string  (** Resolved against the workspace base path. *)
  ; control_path_dir : string  (** Existing 0700 ControlPath directory. *)
  }

type container_exec =
  { prefix : string list
    (** The whole exec argv up to and including the guest name, built by the
        declaring runtime ({!Keeper_sandbox_microvm.shim_exec_prefix_for}).
        It is prebuilt rather than assembled here because the three runtimes
        disagree on more than the executable -- the stdin flag, whether a
        separator precedes the command, and whether the identity the shim
        runs as can be given as [uid:gid] at all -- and one of them cannot
        express that last one, which a function returning an argv could not
        say. *)
  ; probe_prefix : string list option
    (** The exec argv without stdin-streaming flags for probe executions.
        When [None], falls back to [prefix]. *)
  ; container_name : string  (** The running guest. *)
  ; shim_path : string  (** Absolute guest path of [masc-exec-shim]. *)
  }

type transport =
  | Openssh of openssh
  | Container_exec of container_exec

type t

val of_openssh : base_path:string -> keeper_name:string -> openssh -> t
(** Endpoint name, remote root, env allowlist, connect timeout and session
    ceiling come from the registry entry; the keeper's GitHub identity is
    [<remote_root>/<keeper>/.config/gh], as the bootstrap installs it. *)

val of_container_exec :
  base_path:string ->
  keeper_name:string ->
  remote_root:string ->
  gh_config_dir:string ->
  injected_env:(string * string) list ->
  env_allowlist:string list ->
  connect_timeout_sec:int ->
  max_concurrent_sessions:int ->
  container_exec ->
  t
(** A guest endpoint. [remote_root] is the guest path of the work volume and
    [gh_config_dir] the guest path of the mounted GitHub identity snapshot.
    [injected_env] is server-authored env sent with every request beyond
    [GH_CONFIG_DIR] and [GIT_TERMINAL_PROMPT] (the guest's config mount);
    the guest's shim must allowlist those names in its config for them to
    reach the payload. *)

val name : t -> string
(** Endpoint name for logs and error codes: the registry key for OpenSSH,
    the container name for a guest. *)

val remote_root : t -> string
val remote_keeper_root : t -> string
(** [<remote_root>/<sanitized keeper name>]. *)

val gh_config_dir : t -> string
(** Where this endpoint's [gh] keeps the Keeper's identity, and the value the
    lane injects as [GH_CONFIG_DIR] on every request:
    [<remote_keeper_root>/.config/gh] for OpenSSH, the mounted snapshot path
    for a guest. *)

val transport : t -> transport

val injected_env : t -> (string * string) list
(** The server-authored env every request carries: [GH_CONFIG_DIR] and
    [GIT_TERMINAL_PROMPT], then the endpoint's own injected pairs. *)

val keeper_root : remote_root:string -> keeper_name:string -> string

val lane_prefix : transport -> string
(** ["remote_ssh"] or ["microvm_remote"]: the prefix every lane-specific
    error code starts with. *)

val transport_argv : t -> string list
(** Exact argv that delivers the framed request to the shim: the pinned
    OpenSSH argv ending in the fixed remote command [masc-exec-shim], or the
    guest's prebuilt exec prefix with the guest path of the shim appended. *)

val probe_argv : t -> string list
(** {!transport_argv} with the shim asked for [--probe]. *)

val check_preflight : ?force:bool -> t -> (unit, string) result
(** Verify endpoint reachability, shim major version, remote git/rg, the
    roots, free disk, and per-keeper GitHub identity. Results are cached for
    [Env_config_sandbox.Preflight.ssh_ttl_sec] unless [force=true]. *)

val observe_supported : t -> bool
(** Whether this endpoint's shim advertises the box (RFC-0422): the
    [observe] capability in its [--probe] answer. Probes the endpoint once
    per process when nothing has asked yet, and remembers the answer with
    the endpoint's shared state. A probe that fails, or a shim that predates
    the box, is [false]; the caller then leaves the request with the judge. *)

val runner :
  ?mode:Exec_ssh_protocol.mode -> timeout_sec:float -> t -> Masc_exec.Sandbox_target.runner
(** Construct a Shell IR runner. [mode] is the box the request asks the shim
    to build, {!Exec_ssh_protocol.Effect} when omitted; a caller passes
    [Observe] or [Guest_local] only for an endpoint {!observe_supported}
    answered yes for. The local wall-clock budget includes the
    endpoint connect timeout and a bounded drain grace in addition to the
    remote payload timeout. *)

module For_testing : sig
  val clear_preflight_cache : unit -> unit
end
