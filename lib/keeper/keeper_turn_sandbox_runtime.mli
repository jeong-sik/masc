(** Turn-scoped handle on a keeper-lifetime sandbox container.

    Lazily ensures one hardened container per keeper (adopting what a previous
    turn or server left running) and reuses it across compatible tool calls.
    A Docker container mounts the keeper playground read-write and takes
    commands by [docker exec]; a microvm guest owns its tree on a work volume
    and takes commands through the remote lane, so the exec entrypoints here
    refuse it. The root filesystem stays read-only either way. Turn cleanup
    drops the handle without removing the container; the keeper's shutdown
    finalization removes it. *)

type t

type state =
  | Not_started
  | Running of { container_name : string }

val create :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  image:(string, Keeper_sandbox_image_resolver.error) result ->
  ?network_mode:Keeper_types_profile_sandbox.network_mode ->
  unit ->
  t
(** [image] is what the turn resolved the Keeper's [sandbox_image] to. A
    runtime holding an [Error] starts no container and says why. *)

val host_root : t -> string

val image : t -> (string, Keeper_sandbox_image_resolver.error) result
(** The image this runtime's turn resolved, given to {!create}. *)

val image_unresolved_message : Keeper_sandbox_image_resolver.error -> string
(** The refusal a start gives when the turn's image did not resolve. *)

val github_identity_secret_files : t -> string list
(** Credential files of the microvm identity snapshots already bound to this
    runtime, including retained snapshots. Reads the in-memory binding only:
    no token refresh, boot or guest replacement. A boxed execution has already
    acquired that binding; inspecting its output must not prepare a different
    identity after the command ran. *)

type github_identity_preparation_error =
  | Sandbox_unavailable of string
      (** The guest or container could not be started, adopted or replaced. *)
  | Identity_unavailable of string
      (** The Keeper's GitHub identity is what failed: a token refresh, the
          snapshot or revision check, or a start that refused the identity. *)

val github_identity_preparation_error_message :
  github_identity_preparation_error -> string

val prepare_github_identity_secret_files :
  ?timeout_sec:float -> t -> (string list, github_identity_preparation_error) result
(** After authorization, observe and bind the container to the current GitHub
    identity, then return every credential file whose token must remain
    redacted. [Sandbox_unavailable] comes from the guest start, adoption or
    replacement boundary; [Identity_unavailable] comes from the identity
    itself, whether a direct refresh, snapshot or revision check, or a start
    that refused the identity. Callers must branch on the constructor, not on
    the detail text.

    Docker: the bind is [ensure_started] itself and the redaction target is the
    stable [hosts.yml] the running container has mounted; a central login
    reaches it through the mount. Microvm prepares an intended boot-time host
    snapshot; a drift from the central revision drops the handle so the next
    boot rebuilds it. Apple observation does not prove the guest's mounted
    inode. *)

val cleanup : t -> unit
(** Best-effort teardown. Safe to call multiple times. *)

val microvm_remote_endpoint_of_running :
  t -> container_name:string -> (Keeper_sandbox_remote.t, string) result
(** The running guest as a remote endpoint (RFC-0400): [container exec] into
    [container_name] delivering the framed request to the intended shim, the
    work volume as the remote root, the intended guest identity path as
    [GH_CONFIG_DIR] (and its derived credential config as
    [GIT_CONFIG_GLOBAL] when the keeper has a configured GitHub identity), and
    the config env naming the mounted config. Refused for a non-microvm keeper.
    Verifies the process's shared shim readiness. For Apple, it validates the
    host-side credential snapshot, observes the named running guest and checks
    its workspace, keeper and network labels before returning the endpoint.
    This proves neither the guest's mounted inode nor a fence against later
    guest replacement. Does not start a guest or prepare build output. *)

val microvm_remote_endpoint :
  ?timeout_sec:float -> t -> (Keeper_sandbox_remote.t, string) result
(** {!microvm_remote_endpoint_of_running} after ensuring the guest is up.
    Apple completes its first process handoff under Keeper lifecycle ownership,
    including durable identity validation, shim verification and build cleanup.
    Its final endpoint admission rechecks readiness under that same owner; if
    an observation invalidated it in between, this call fails and can be retried. *)

val microvm_attached_endpoint :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (Keeper_sandbox_remote.t, string) result
(** The keeper's guest as an endpoint, without a turn. The guest name is a
    function of the keeper and the base path and the guest is keeper-lifetime,
    so a caller without a turn can reach one that is up. Apple briefly borrows
    Keeper lifecycle ownership to validate the host-side durable identity and
    observe the guest's labels.

    Never starts a guest. Apple refuses an absent, stopped, unreadable or
    differently scoped guest before returning an endpoint; the observation
    does not fence a subsequent replacement. Other backends still reach the
    guest through [container exec]. For Apple, [timeout_sec] applies to guest
    inspection, not to the entire endpoint acquisition. Booting for a reader
    would spend a VM start and write the identity snapshot and work root, which
    belong to the keeper's turn.
    Refused for a non-microvm keeper. *)

val with_apple_snapshot_endpoint :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  (revision:string -> Keeper_sandbox_remote.t -> ('a, string) result) ->
  ('a, string) result
(** Capture the host-side snapshot and endpoint route under the process-local
    Keeper lifecycle owner without observing the guest. The callback must only
    capture or inspect the route; it must never execute a guest command or
    reacquire the owner. A later guest effect needs its own guest observation. *)

val with_apple_attached_endpoint :
  ?timeout_sec:float -> config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  (revision:string -> Keeper_sandbox_remote.t -> ('a, string) result) ->
  ('a, string) result
(** Validate the Apple guest's scope labels and host-side credential snapshot
    under the process-local Keeper lifecycle owner. The callback must only inspect the endpoint, not
    execute a guest command or reacquire the owner. The optional timeout bounds
    the guest inspection, not the full acquisition and validation. The revision
    identifies the validated snapshot; it does not prove which inode the guest
    actually mounted. Changes after inspection are not fenced. *)

val microvm_guest_absence_reason :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  string option
(** [Some reason] when this keeper's guest is not running, for a caller that
    already holds a failure and wants the fact behind it. [None] when the
    guest is up, when the probe could not answer, or when the keeper is not a
    microvm -- in each of those the caller keeps its own error rather than
    replacing it with a guess. A confirmed observation invalidates work-root
    and shim readiness for the backend and name. In Eio, observation and
    invalidation hold the process-local Keeper lifecycle lock. Apple returns
    [None] outside Eio. This does not fence another server's guest changes. *)

val is_microvm_guest_booted :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  bool
(** Pure in-memory check for the current base, backend and guest name. Returns
    false when the backend is unspecified or this process has not prepared that
    guest's work volume root. *)

val forget_microvm_guest_booted :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  unit
(** Evicts every base's work-root and shim readiness for the same backend and
    guest name (e.g. after it was observed stopped or dead). Other backends,
    process boot records and identity snapshots are not evicted. A caller
    pairing this with an observation must hold the Keeper lifecycle owner;
    {!microvm_guest_absence_reason} performs the pair under that owner. *)

(** What a microvm guest this process booted was booted with. Adopt matches a
    guest by name, which carries none of these, so each is recorded at boot
    and compared before a running guest is adopted. *)
type microvm_boot =
  { policy_port : int option
      (** The egress proxy port in a [Network_policy] guest's environment;
          [None] in the other modes. *)
  ; image : string
  ; guest_size : Keeper_microvm_guest_size.t
  }

type microvm_replacement_reason =
  | Boot_not_recorded
      (** This process has no record of booting the guest, so what it was
          given is unknown. *)
  | Image_changed of
      { booted : string
      ; target : string
      }
  | Memory_changed of
      { booted : Keeper_microvm_guest_size.memory
      ; target : Keeper_microvm_guest_size.memory
      }
  | Cpus_changed of
      { booted : Keeper_microvm_guest_size.cpus
      ; target : Keeper_microvm_guest_size.cpus
      }
  | Policy_route_stale of
      { booted_port : int option
      ; bound_port : int option
      }
      (** {!For_testing.policy_route_holds} said no. *)

type microvm_adoption =
  | Adopt_running_guest
  | Replace_running_guest of microvm_replacement_reason list
      (** Never empty: every reason the guest may not be adopted. *)

module For_testing : sig
  val create_minimal
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> state:state
    -> t

  val get_state : t -> state
  val set_state : t -> state -> unit
  val keeper_docker_container_name : t -> string
  (** The stable per-keeper container name, so the naming contract (stable
      across turns, split by network mode, bound to the base path) is
      testable without a docker daemon. A {!create_minimal} runtime holds a
      fixed image. *)

  val policy_route_holds
    :  network_mode:Keeper_types_profile_sandbox.network_mode
    -> booted_port:int option
    -> bound_port:int option
    -> bool
  (** Whether a running guest may be adopted rather than replaced, on the
      question of its network route alone. A [Network_policy] guest carries
      the lane's proxy port in its environment; the port is ephemeral and the
      guest is not, so the two can part. Answering this without a guest or a
      registry keeps the rule testable. *)

  val microvm_adoption
    :  booted:microvm_boot option
    -> image:string
    -> guest_size:Keeper_microvm_guest_size.t
    -> network_mode:Keeper_types_profile_sandbox.network_mode
    -> bound_port:int option
    -> microvm_adoption
  (** Whether a running guest whose identity snapshot this process holds may
      be adopted, given what it was [booted] with and what the keeper asks
      for now. No record, another image, another memory or CPU count, or a
      policy route {!policy_route_holds} rejects each means replace, and every
      one that applies is named. *)

  val microvm_boot_nameserver
    :  backend:Keeper_microvm_backend.t
    -> network_mode:Keeper_types_profile_sandbox.network_mode
    -> (Ipaddr.t option, string) result
  (** The nameserver a guest is booted with: the one the workspace named, else
      the host's resolver. [Error] when there is none a guest can use. [Ok
      None] where no [--dns] is spelled: the other network modes and
      Microsandbox. The start reads it after deciding to boot and before it
      stops or deletes anything for that boot. *)
end

module For_testing_microvm : sig
  type build_link_generation

  val build_link_generation :
    base_path:string -> backend:Keeper_microvm_backend.t -> container_name:string -> build_link_generation option
  val complete_build_link_scan :
    base_path:string -> backend:Keeper_microvm_backend.t -> container_name:string -> build_link_generation -> bool
  val build_link_scan_prepared :
    base_path:string -> backend:Keeper_microvm_backend.t -> container_name:string -> bool
  (** Expose the process-local generation guard for the stale-completion test. *)

  val microvm_identity_snapshot_registered : container_name:string -> bool
  (** Whether a guest name still owns a snapshot; exposes no credential data. *)

  val microvm_container_name
    :  config:Workspace.config
    -> keeper_name:string
    -> network_mode:Keeper_types_profile_sandbox.network_mode
    -> string
  (** The stable per-keeper guest name. Apart from {!For_testing} because it
      is defined below it, and exposed for the same reason its Docker sibling
      is: a test that boots a guest has to be able to name the one it booted,
      and the mode belongs in that name so a guest from one policy is never
      adopted under another. *)

  val mark_microvm_guest_booted
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> unit
    -> unit

  val mark_microvm_work_root_ready :
    base_path:string -> backend:Keeper_microvm_backend.t -> container_name:string -> unit
  val microvm_work_root_ready :
    base_path:string -> backend:Keeper_microvm_backend.t -> container_name:string -> bool
  (** Exercise colliding guest names across independently scoped bases. *)

  val record_process_boot : container_name:string -> microvm_boot -> unit
  val process_boot : container_name:string -> microvm_boot option
  val register_process_identity : container_name:string -> cleanup:(unit -> unit) -> bool
  (** Exercise whether another backend's process-owned boot record survives
      an Apple observation or teardown of the same name. The identity helper
      registers a synthetic process-owned snapshot with the supplied cleanup. *)

  val ensure_work_volume_mounted
    :  ?timeout_sec:float
    -> t
    -> backend:Keeper_microvm_backend.t
    -> container_name:string
    -> (unit, string) result
  (** Exercise the same guest mount admission used during boot and adoption. *)

  val provision_guest
    : t -> backend:Keeper_microvm_backend.t -> timeout_sec:float -> (unit, string) result
  (** Exercise the boot provisioning path without exposing its private record. *)
end

val container_cwd_of_host :
  t -> host_cwd:string -> string

val run_argv_with_stdin_and_status_split :
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?output_capture:Process_output_capture.t ->
  stdin_content:string ->
  string list ->
  Unix.process_status * string * string
(** Run a sandbox-management argv with stdin through the owned Docker execution
    boundary exactly once. The returned status, stdout, and stderr are the
    subprocess result without text-based classification, retry, or output
    suppression. This is intentionally lower-level than the turn-scoped [t]
    operations because one-shot sandbox startup paths need the same execution
    boundary before a reusable container exists. *)

val run_command_with_status :
  ?ok_exit_codes:int list ->
  timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  max_bytes:int ->
  unit ->
  (Unix.process_status * string, string) result

val exec_argv :
  ?stdin:bool ->
  ?timeout_sec:float ->
  validate_cached_container:bool ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (string list, string) result
(** The argv that runs [command_argv] inside the turn-scoped container.

    Exactly what {!run_exec_with_status_split} blocks on, handed over instead
    of run: a command that must not hold the turn is spawned, and it has to
    land in the same container as the same uid under the same rewritten paths.
    Building that argv twice would be building the boundary twice. *)

val run_exec_with_status_split :
  ?stdin_content:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (Unix.process_status * string * string, string) result
(** Execute [command_argv] inside the turn-scoped container and return split
    stdout/stderr without applying success-code policy. This is the argv-level
    entrypoint used by Shell IR dispatch. *)

val run_exec_with_output_files :
  ?stdin_content:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  capture_dir:string ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (Unix.process_status * string * string * Process_output_capture.files option, string) result
(** The same execution and container recovery path as
    {!run_exec_with_status_split}, with fresh private output files per actual
    process attempt. Capture errors never alter the command's status or cause
    a retry. The returned files belong to the final attempt; prior attempt
    files are retained under [capture_dir]. Cancellation closes and retains
    partial files before propagating. *)

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

val run_exec_pipeline_with_status :
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  t ->
  cwd:string ->
  stages:exec_pipeline_stage list ->
  (Unix.process_status * string * string, string) result
(** Execute [stages] as a streaming argv pipeline inside the turn-scoped
    container. Each stage is a separate [docker exec -i] process and adjacent
    stages are connected by host-side process pipes. *)

val run_bash_with_status :
  timeout_sec:float ->
  t ->
  cwd:string ->
  cmd:string ->
  unit ->
  (Unix.process_status * string, string) result

val teardown_keeper_sandbox_by_name :
  ?timeout_sec:float ->
  config:Workspace.config ->
  keeper_name:string ->
  backend:Keeper_sandbox.backend ->
  ?microvm_backend:Keeper_microvm_backend.t ->
  unit ->
  (unit, string) result
(** {!teardown_keeper_sandbox} for callers that hold the keeper's name and
    typed backend -- shutdown finalization, which runs after the registry
    entry is gone. A remote-SSH Keeper owns no local container;
    Docker and microVM teardown target only their declared runtime.
    Apple teardown observes the stable trim and repair helper names but never
    removes them without workspace ownership. Before removing an Apple guest,
    its observed stable ownership and network labels must match the request;
    missing or different labels are refused before any guest removal. This
    observation does not fence replacement between inspection and removal.
    After the ownership preflight, presence or unreadable helper inventory is
    reported after all guest names are attempted. An explicit [timeout_sec]
    also bounds the helper inventory; otherwise it uses the I/O budget. The
    first guest error wins, otherwise the helper observation result is returned.

    A [Micro_vm] teardown with no [microvm_backend] is
    [microvm_teardown_backend_unresolved] rather than an assumed runtime:
    sending [container delete --force] to a guest another runtime booted
    reports success while the guest keeps running. *)

val remove_keeper_volumes_by_name :
  ?timeout_sec:float ->
  keeper_name:string ->
  backend:Keeper_sandbox.backend ->
  ?microvm_backend:Keeper_microvm_backend.t ->
  unit ->
  (unit, string) result
(** Decide whether a dissolved keeper's volumes can be removed after
    {!teardown_keeper_sandbox_by_name}. Teardown alone leaves them, because a
    paused keeper is torn down too and comes back to its work volume.

    Apple volume names are shared by same-named Keepers in different
    workspaces. Until durable ownership can establish which workspaces own a
    volume, automatic deletion returns an error and leaves it in place.
    Docker and remote SSH keepers own no volume.
    Microsandbox and nerdctl create the work volume as a host directory but
    have no established removal spelling, so they return [Error] naming the
    volume left behind, as does a [Micro_vm] keeper with no
    [microvm_backend]. [timeout_sec] is retained for callers; no backend here
    issues a volume deletion command while ownership remains unverified. *)

val teardown_keeper_sandbox :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (unit, string) result
(** Remove the keeper-lifetime containers for [meta]: the microvm guest and
    the persistent Docker containers, if any. Turn cleanup deliberately
    leaves both running (the guest boot and the container start are paid
    once per keeper, not per turn); this is the remove path, run at keeper
    shutdown finalization. A missing container is a successful teardown.
    The MicroVM identity snapshot is released only after its guest has
    stopped and been deleted. *)

val sweep_abandoned_microvm_guests :
  base_path:string ->
  command_available:(string -> bool) ->
  timeout_sec:float ->
  is_pid_alive:(int -> bool) ->
  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string) ->
  (Keeper_microvm_backend.t * Keeper_sandbox_microvm.sweep_outcome) list
(** Collect abandoned guests with exclusive lifecycle inventory ownership
    from listing through deletion. Apple preserves current declared guest
    names regardless of owner PID and revalidates the declaration and the
    named guest's ownership labels before each deletion; uncertain inventory,
    declarations or labels preserve guests. The observation does not fence a
    replacement before deletion. Other
    backends retain their process ownership rules. Ordinary
    lifecycle operations serialize per Keeper; different Keepers may prepare
    concurrently whenever inventory maintenance is not active. *)

type build_cleanup_report = { cleaned : int; failed : int }

val build_cleanup_report_of_string : string -> (build_cleanup_report, string) result
(** Decode a completed guest sweep. A guest that skipped the sweep reports its
    reason as an error rather than successful empty maintenance. *)

(** Attach-only artifact cleanup. Caller must hold the Owner maintenance slot.
    Unsupported or absent guests are skipped; this never boots a guest. *)
val cleanup_attached_builds : config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta -> retention_sec:float -> unit ->
  (build_cleanup_report option, string) result
