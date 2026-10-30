(** Framed exec-shim runner for OpenSSH, MicroVM and Docker Observe.
    All transports use the same protocol and actual child receipts. *)

type openssh =
  { endpoint : Exec_ssh_endpoint.t
  ; ssh_bin : string
  ; identity_file : string  (** Resolved against the workspace base path. *)
  ; known_hosts_file : string  (** Resolved against the workspace base path. *)
  }

type container_exec =
  { prefix : string list
    (** The whole exec argv up to and including the guest name, built by the
        declaring runtime ({!Keeper_sandbox_microvm.shim_exec_prefix_for}).
        It is prebuilt rather than assembled here because the three runtimes
        disagree on more than the executable -- the stdin flag, whether a
        separator precedes the command, and how the identity the shim
        runs as is mapped. *)
  ; probe_prefix : string list option
    (** The exec argv without stdin-streaming flags for probe executions.
        When [None], falls back to [prefix]. *)
  ; container_name : string  (** The running guest. *)
  ; shim_path : string  (** Absolute guest path of [masc-exec-shim]. *)
  }

type transport =
  | Openssh of openssh
  | Container_exec of container_exec
  | Docker_exec of container_exec

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
    [injected_env] is server-authored env (the guest's config mount) sent
    with every request beyond [GH_CONFIG_DIR], [GIT_TERMINAL_PROMPT] and the
    Keeper's commit names ({!Exec_ssh_protocol.keeper_git_author_env});
    the guest's shim must allowlist those names in its config for them to
    reach the payload. *)

val of_docker_exec :
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
(** Docker's framed Observe transport. The runtime supplies the actual
    running container, shim path and exec argv. Payload cwd/argv already use
    guest paths. Only [Observe] is accepted: a Docker guest may mount host
    files read-write, so neither [Guest_local] nor [Effect] is observational.
    This constructor does not provision a shim or start a container. *)

val name : t -> string
(** Endpoint name for logs and error codes: the registry key for OpenSSH,
    the container name for a guest. *)

val workspace_root : t -> string
(** The exact request jail/default cwd used by ordinary payloads. *)

val keeper_root : remote_root:string -> keeper_name:string -> string
(** Pure per-Keeper endpoint root shared by namespace resolution and transport. *)

val keeper_control_root : t -> string
(** OpenSSH [<endpoint_root>/<sanitized keeper name>], currently both its
    workspace and Keeper-scoped GitHub control root. The separate name
    prevents callers from inferring either role from the endpoint root. *)

val gh_config_dir : t -> string
(** Where this endpoint's [gh] keeps the Keeper's identity, and the value the
    lane injects as [GH_CONFIG_DIR] on every request:
    [<keeper_control_root>/.config/gh] for OpenSSH, the mounted snapshot path
    for a guest. *)

val transport : t -> transport

(** Guest-local execution through this Keeper microVM runner is unavailable
    while named volumes cannot be verified as exclusive to the workspace. This reason is
    used both when selecting the observation route and when refusing a direct
    framed request. It does not establish isolation for other execution modes. *)
val microvm_guest_local_unavailable_reason : string

val injected_env : t -> (string * string) list
(** The server-authored env every request carries: [GH_CONFIG_DIR],
    [GIT_TERMINAL_PROMPT], [GIT_AUTHOR_NAME] and [GIT_COMMITTER_NAME] (both
    the Keeper's name), then the endpoint's own injected pairs. *)

val lane_prefix : transport -> string
(** ["remote_ssh"], ["microvm_remote"] or ["docker_observe"]: the prefix every lane-specific
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

val check_endpoint_preflight : t -> (unit, string) result
(** Uncached endpoint-root half of the OpenSSH preflight. GitHub login uses
    this before its one fixed Keeper-workspace bootstrap. A transport or shim
    refusal during the framed check remains a preflight-unavailable error;
    a missing-root error means the remote check actually executed and returned
    a nonzero status. Probe failures retain their probe diagnostics. *)

val check_workspace_preflight : t -> (unit, string) result
(** Uncached Keeper-workspace structure check. It verifies only that the
    request root exists, so GitHub login is not blocked by payload tool or disk
    readiness. Transport or shim refusals remain preflight-unavailable errors,
    rather than claiming that the Keeper root is absent. Ordinary payloads use
    the full cached {!check_preflight}. *)

val invalidate_preflight : t -> unit
(** Forget this endpoint and Keeper's cached preflight after bootstrap or
    login changes the remote workspace or identity. *)

val observe_supported : t -> bool
(** Whether this endpoint's shim advertises the box (RFC-0422): the
    [observe] capability in its [--probe] answer. Probes the endpoint once
    per process when nothing has asked yet, and remembers the answer with
    the endpoint's shared state. A probe that fails, or a shim that predates
    the box, is [false]; the caller then leaves the request with the judge. *)

(** {1 Lane report (RFC-0427 D-1)}

    What this process knows about the endpoint from its own probes and
    dispatches: a projection kept with the endpoint's shared state, never
    stored, empty after a restart. Each [dispatch_failure] is one return
    branch of {!runner}; the class is decided at the branch, not read out of
    the message. *)

type dispatch_failure =
  | Local_timeout  (** the host budget ran out before the shim answered *)
  | Remote_timeout  (** the shim's own timer killed the payload *)
  | Transport_failed
      (** no readable trailer: the connection, the transport's exit, or a
          trailer this build cannot read; a version error names itself in
          the detail *)
  | Shim_refused  (** the shim answered a [shim_error]: jail, config, box *)
  | Trailer_disagreement  (** transport status and trailer contradict *)

type dispatch_record =
  | Payload_finished of
      { at : float
      ; status : Unix.process_status
      }
  | Dispatch_failed of
      { at : float
      ; failure : dispatch_failure
      ; detail : string
      }

type boot_change = Boot_unreported | Boot_first | Boot_unchanged | Boot_changed

type boot_observation =
  { boot_id : string option
  ; change : boot_change
  ; last_changed_at : float option
  }
(** Comparison with the last known boot UUID in this server process, for the
    same complete endpoint declaration. A change may be a reboot or endpoint
    replacement. Neither result proves workspace continuity. *)

type probe_report =
  | Probe_not_asked
  | Probe_answered of
      { major : Exec_ssh_protocol.major
      ; capabilities : string list
      ; release : string option
          (** The MASC release the shim was built from, as it named itself in
              the probe. [None] from a shim built before the field existed,
              which the server treats as a skew and says so once
              ([remote_shim_outdated], RFC-0427 B-3). *)
      ; observed_at : float
          (** Unix time this process got the probe's answer. The answer is
              kept for the life of the process, so it is the shim as of this
              moment and not necessarily the shim now. *)
      ; boot : boot_observation
      }
  | Probe_failed of
      { at : float
      ; detail : string
      }

type lane_report =
  { lane : string  (** {!lane_prefix} of the transport *)
  ; endpoint : string  (** {!name} *)
  ; probe : probe_report
  ; last_dispatch : dispatch_record option
  }

val outdated_shim_repair : t -> string
(** What an operator does when this endpoint's shim came from another release
    than this server, as the [remote_shim_outdated] WARN says it. The shim is
    installed in a different place per transport: on the remote host for
    OpenSSH and in this host's microVM shim directory for a microVM guest.
    For Docker the server knows only the path it execs in the container, and
    the sentence says no more than that. *)

type dispatch_scope = Endpoint_dispatch | Keeper_dispatch of string

val report_openssh : scope:dispatch_scope -> base_path:string -> openssh -> lane_report
(** Read observations bound to this complete endpoint declaration and resolved
    transport configuration without creating a runner,
    cache entry, or remote probe. A changed host, root, credential path, policy
    or transport does not inherit the previous declaration's observations.
    The probe describes the shared endpoint. [Keeper_dispatch name] returns
    that Keeper's last dispatch on the endpoint, or [None] if it has not
    dispatched there in this process. [Endpoint_dispatch] returns the latest
    dispatch from any Keeper sharing the endpoint.
    File contents replaced at an unchanged credential path are not identified
    by this observation key. Each transport invocation nevertheless opens a
    new connection and authenticates against the current dedicated key and
    pinned hosts file; cached observations never authorize a connection. *)

val report : t -> lane_report
(** The endpoint's shared probe and this runner's Keeper-specific last dispatch. *)

(** Whether the shim confirmed, on the front of its stderr, that it accepted
    this request. Evidence kept beside an unknown effect for the operator and
    for measuring how many unknowns never reached the shim; no classification
    reads it. [Acceptance_not_asked] is a shim that does not advertise the
    frame, so its absence says nothing. *)
type acceptance_evidence =
  | Acceptance_not_asked
  | Acceptance_not_read
  | Acceptance_read

type receipt_unavailable =
  | Request_not_sent
  | Transport_unavailable of acceptance_evidence
  | Peer_receipt_missing
  | Invalid_receipt of string
  | Shim_refused_without_receipt

type execution_observation =
  | Execution_observed of Exec_ssh_protocol.execution_receipt * Exec_ssh_protocol.trailer
  | Execution_unavailable of receipt_unavailable

val execution_observation_to_yojson : execution_observation -> Yojson.Safe.t

type stdout_mode = Text_paths | Binary_bytes
(** Binary_bytes collects raw stdout chunks without text capture limits or path rewriting. *)

val runner :
  ?stdout_mode:stdout_mode ->
  ?mode:Exec_ssh_protocol.mode ->
  ?on_receipt:(execution_observation -> unit) ->
  timeout_sec:float -> t -> Masc_exec.Sandbox_target.runner
(** Construct a Shell IR runner. [mode] is the box the request asks the shim
    to build, {!Exec_ssh_protocol.Effect} when omitted; a caller passes
    [Observe] or [Guest_local] only for an endpoint {!observe_supported}
    answered yes for. Docker accepts only [Observe], even when called without
    an explicit mode. This Keeper microVM runner rejects [Guest_local] before sending a request;
    [Effect] and [Observe] retain their existing behavior. OpenSSH and guest requests use the Keeper workspace as
    both request root and default cwd; Docker uses its already-resolved workdir.
    The local wall-clock budget includes the
    endpoint connect timeout and a bounded drain grace in addition to the
    remote payload timeout.

    [on_receipt] receives only this runner call's response evidence. The caller
    owns its collection; endpoint-wide [last_dispatch] is never consulted. *)

val bootstrap_keeper_control_root :
  timeout_sec:float -> t -> Masc_exec.Sandbox_target.run_outcome
(** Create an OpenSSH Keeper's control root with one fixed [mkdir] request
    rooted at the endpoint base. Under the current per-Keeper layout this is
    also its workspace. Ordinary payloads cannot select the wider endpoint
    root. Other transports are already provisioned by their runtime and fail
    here. *)

module For_testing : sig
  val clear_preflight_cache : unit -> unit
  val run_probe : t -> (Exec_ssh_protocol.major, string) result
end
