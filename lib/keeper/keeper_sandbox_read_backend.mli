(** Keeper sandbox read backend implementation.

    RFC-0006 Phase B-2: hardened keepers route read-side operations through the
    selected sandbox backend so the backend mount restrictions are the
    load-bearing boundary instead of a host-side string check. The current
    concrete backend uses Docker, but callers should depend on
    {!Keeper_sandbox_read_runner} instead of this module.

    The host-side containment check from Phase B-1 remains as
    defense in depth and is still applied before this module is
    consulted. *)

(** [should_route_read ~meta] is [true] iff this keeper's reads
    should go through the sandbox backend. Encapsulates the
    [sandbox_profile=docker|micro_vm|remote_ssh] policy so callers do not have
    to repeat it. *)
val should_route_read : meta:Keeper_meta_contract.keeper_meta -> bool

(** Translate a runner's [run_outcome] into a read result. A
    [Transport_failed] is always an [Error]; a [Ran] result applies
    [ok_exit_codes] to its exit status. Exposed for the differential test that
    pins the distinction: a down lane must not read as an empty [Ok] on the
    Grep lane (whose [ok_exit_codes] accepts exit 1). *)
val classify_read_outcome :
  lane:string ->
  endpoint_name:string ->
  ok_exit_codes:int list ->
  max_bytes:int ->
  Masc_exec.Sandbox_target.run_outcome ->
  (Unix.process_status * string, string) result

(** [container_path_of_host ~config ~meta ~host_path] maps a host-side
    absolute playground path to its selected backend counterpart (container or
    SSH endpoint). Returns [Error _] when [host_path] is not inside the
    keeper's playground bundle (programmer error — caller should have
    run the containment check first). *)
val container_path_of_host :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  host_path:string ->
  (string, string) result

(** [read_file ~config ~meta ~host_path ~max_bytes ~timeout_sec ()] reads
    [host_path] through the selected sandbox backend and returns the captured
    bytes (clamped to [max_bytes]). Docker mounts the playground read-only;
    SSH invokes the fixed remote shim and never probes the host path first.

    Errors include backend image misconfiguration, backend command failure, or
    the input not being inside the playground. *)
val read_file :
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  host_path:string ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, string) result

(** [run_command ~config ~meta ~command_argv ~max_bytes ~timeout_sec ()] is the
    general-purpose primitive that [read_file] is built on. It runs the same
    hardened backend prelude (read-only rootfs, no caps, no network, playground
    mounted read-only at [Keeper_sandbox.container_root meta.name]) and appends
    [command_argv] as the program + arguments executed inside the backend
    runtime.

    The caller owns container-path translation: any path referenced
    in [command_argv] must already be in container space (use
    [container_path_of_host] to convert). The first element of
    [command_argv] is the executable.

    Returns the captured stdout bytes clamped to [max_bytes]. Errors
    include image misconfiguration, empty [command_argv], runtime
    preflight failure, and backend command failure. A backend command
    failure tags the program name (e.g. [docker_rg_failed]); the
    host-path preflight in {!read_file} tags the sandbox profile
    (e.g. [microvm_read_failed]) since no backend ran. Both are for
    caller log forensics. *)

type read_dispatch =
  | Turn_runtime of Keeper_sandbox_factory.runtime_binding
      (** The turn's frozen guest runtime. *)
  | Remote_dispatch
      (** The lane's endpoint, which a turn may start. *)
  | Attached_guest
      (** A running guest named by the keeper and the base path, reached
          without a turn and never started by the read. *)
  | Docker_fallback
      (** A read-only container over the shared playground mount. *)

val resolve_read_dispatch :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  (read_dispatch, string) result
(** Which backend reaches this keeper's tree, decided from the declared
    profile and what the caller holds. Pure: it performs no read and starts
    nothing.

    Exposed because the routing table is this module's load-bearing decision
    and a wrong arm is invisible at the call site — a microvm read was
    refused as unreachable for as long as the arm said so, while the guest
    was up and named by facts the caller already had. *)

val run_command_with_status :
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?ok_exit_codes:int list ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (Unix.process_status * string, string) result

(** [run_command ?ok_exit_codes ~config ~meta ~command_argv
    ~max_bytes ~timeout_sec ()] is a convenience wrapper around
    [run_command_with_status] that drops the returned
    process status and keeps only the captured stdout bytes. *)
val run_command :
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?ok_exit_codes:int list ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, string) result
