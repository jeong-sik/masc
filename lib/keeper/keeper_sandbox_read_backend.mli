(** Keeper sandbox read backend implementation.

    Hardened keepers route read-side operations through the selected sandbox
    backend so the backend mount restrictions are the load-bearing boundary
    instead of a host-side string check. The backend is a Docker container, a
    microVM guest or an SSH endpoint, but callers should depend on
    {!Keeper_sandbox_read_runner} instead of this module.

    The host-side containment check remains as defense in depth and is still
    applied before this module is consulted. *)

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
    SSH endpoint). On an OpenSSH endpoint, a path outside the keeper's tree
    that lies under the endpoint's declared roots
    ({!Keeper_sandbox_remote_lane.declared_endpoint_path}) is the endpoint's
    own path and returns as itself. Returns [Error _] when [host_path] is
    neither inside the keeper's playground bundle nor such a declared path
    (programmer error — caller should have run the containment check
    first). *)
val container_path_of_host :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  host_path:string ->
  (string, string) result

val container_path_of_host_with_authority :
  read_authority:Keeper_sandbox_remote_lane.read_authority ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  host_path:string -> (string, string) result
(** Translate against exactly the endpoint and declared roots the caller holds. *)

type read_error =
  | Missing_file of string
  | Not_a_file of string
  | Read_failed of string
  | Read_refused of string

val read_error_to_string : read_error -> string

(** A backend path and the backend-side root it was admitted under: the
    keeper's tree on the backend, or the declared endpoint root that
    admitted it. *)
type confined_path = { path : string; root : string }

(** [container_path_of_host] with the root that admitted the path. *)
val confined_path_of_host :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  host_path:string ->
  (confined_path, string) result

(** Why a confined read read nothing, each with its own exit code. *)
type confined_open_refusal =
  | Path_missing  (** Nothing at the path. *)
  | Not_a_regular_file  (** The path names something other than a regular file. *)
  | Open_failed  (** The open itself failed (permission, I/O). *)
  | Outside_root
      (** The file the open reached lies outside the admitting root: a
          symlink on the way led out of the sandbox (#35934). *)
  | Opened_file_unresolved
      (** The backend could not resolve the opened descriptor or the root,
          so containment was not proven. *)
  | Root_moved
      (** The root no longer resolves to the directory it was configured as:
          a component of it was replaced by a symlink, or the root was
          configured through one. The check is against the configured
          spelling, never a root resolved at read time. *)

val confined_open_exit : confined_open_refusal -> int
val confined_open_refusal_of_exit : int -> confined_open_refusal option

(** Every refusal exit, for a caller's [ok_exit_codes]. *)
val confined_open_exits : int list

(** The script text that opens [$2] onto stdin and proves the opened file
    is a regular file under root [$1], exiting with {!confined_open_exit}
    otherwise. [$1] is the root as configured; it must still resolve to
    exactly that spelling ({!Root_moved}). The decision is made on the
    opened descriptor ([/proc/self/fd/0]) in the backend's own view, and the
    reader that follows consumes that same descriptor, so a symlink cannot be
    swapped in between check and read.
    A caller appends its reader (reading stdin) and passes the root, the
    path and its own operands ([$3] onward) as positional arguments. *)
val confined_open_prelude : string

(** The [read_error] a refusal of a read of [host_path] reports, worded
    with the keeper's [profile_label]. *)
val read_error_of_refusal :
  profile_label:string -> host_path:string -> confined_open_refusal -> read_error

(** What a confined read takes from the opened file. *)
type confined_read =
  | Line_window of { start_line : int; max_bytes : int }
      (** At most [max_bytes] from line [start_line] on. *)
  | Byte_prefix of { max_bytes : int }
  | Whole_file

(** The [sh] argv that runs {!confined_open_prelude} on [confined] and then
    [read] on the opened descriptor. *)
val confined_read_argv : confined:confined_path -> confined_read -> string list

(** [read_file ~config ~meta ~host_path ~max_bytes ~timeout_sec ()] reads
    [host_path] through the selected sandbox backend and returns the captured
    bytes (clamped to [max_bytes]). Docker mounts the playground read-only;
    SSH invokes the fixed remote shim and never probes the host path first;
    a missing path or a non-file is [Missing_file] or [Not_a_file] from the
    script's exit code.

    [start_line] (default 1) is the file's line the returned bytes begin at;
    [max_bytes] bounds the bytes from that line, not the file's prefix.

    Errors include backend image misconfiguration, backend command failure, or
    the input not being inside the playground. *)
val read_file :
  ?read_authority:Keeper_sandbox_remote_lane.read_authority ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?start_line:int ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  host_path:string ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, read_error) result

(** [run_command ~config ~meta ~command_argv ~max_bytes ~timeout_sec ()] is the
    general-purpose primitive that [read_file] is built on. It runs the same
    hardened backend prelude (read-only rootfs, no caps, no network, playground
    mounted read-only at [Keeper_sandbox.container_root meta.name]) and appends
    [command_argv] as the program + arguments executed inside the backend
    runtime.

    The caller owns container-path translation: any path referenced
    in [command_argv] must already be in container space (use
    [container_path_of_host] to convert). The first element of
    [command_argv] is the executable. The Docker fallback clears the image's
    default entrypoint so it cannot reinterpret that program or its exit code.

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
  ?read_authority:Keeper_sandbox_remote_lane.read_authority ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?ok_exit_codes:int list ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (Unix.process_status * string, string) result

(** [run_command_with_status] with the capture mode chosen by [max_bytes]:
    [Some n] captures text, rewriting the endpoint's root to the host path,
    and keeps at most [n] bytes; [None] keeps the stdout bytes exactly as the
    command wrote them, so the command itself must bound what it prints. *)
val run_command_with_capture :
  ?read_authority:Keeper_sandbox_remote_lane.read_authority ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?ok_exit_codes:int list ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  command_argv:string list ->
  max_bytes:int option ->
  timeout_sec:float ->
  unit ->
  (Unix.process_status * string, string) result

(** [run_command ?ok_exit_codes ~config ~meta ~command_argv
    ~max_bytes ~timeout_sec ()] is a convenience wrapper around
    [run_command_with_status] that drops the returned
    process status and keeps only the captured stdout bytes. *)
val run_command :
  ?read_authority:Keeper_sandbox_remote_lane.read_authority ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?ok_exit_codes:int list ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, string) result

(** Raw complete endpoint or Docker read. Docker requires authoritative process
    capture EOF; completion-only fallback is refused rather than returning previews. *)
val read_complete_file : ?read_authority:Keeper_sandbox_remote_lane.read_authority -> ?turn_sandbox_factory:Keeper_sandbox_factory.t -> config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  host_path:string -> timeout_sec:float -> unit -> (string, string) result

(** Raw binary prefix. The command limits its output before transport capture;
    it is never projected as UTF-8 text. A path that does not exist or is not a
    regular file is classified like {!read_file}'s window: the sentinel exit
    codes say so, so a caller can distinguish a missing path from a transport
    or capture fault. *)
val read_raw_prefix : ?read_authority:Keeper_sandbox_remote_lane.read_authority -> ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  host_path:string -> max_bytes:int -> timeout_sec:float -> unit ->
  (string, read_error) result
