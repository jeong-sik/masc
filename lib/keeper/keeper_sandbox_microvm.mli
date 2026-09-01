(** Apple [container] argv for the [Micro_vm] sandbox profile.

    Command construction only: nothing here starts a VM. Dispatch does --
    [Keeper_turn_sandbox_runtime] runs these argv for a keeper whose profile
    is [Micro_vm], and has since #31340. See the implementation for the
    measured cost of the backend and for the two Docker hardening flags
    [container run] does not accept. *)

val command_argv : unit -> string list

val unsupported_docker_flags : string list
(** Docker hardening flags [container run] rejects. [container] errors on an
    unknown option rather than ignoring it, so this list is what a reader
    must weigh when choosing the profile, not a runtime fallback. *)

val network_args :
  dns:string option -> Keeper_types_profile_sandbox.network_mode -> string list
(** [Network_inherit] uses container's NAT, which routes outside. It needs a
    nameserver passed in: the guest's resolver points at the gateway and the
    gateway refuses DNS from inside, so without one the guest routes fine and
    resolves nothing. *)

val run_argv :
  container_name:string ->
  container_root:string ->
  container_cwd:string ->
  host_root:string ->
  image:string ->
  network_args:string list ->
  uid:int ->
  gid:int ->
  env_args:string list ->
  memory:string ->
  string list

val image_present : image:string -> timeout_sec:float -> (unit, string) result
(** Gate the run on the image already being in container's store. container
    has no [--pull=never]: without this, a missing image is fetched from a
    registry rather than refused. *)

type image_probe_phase =
  | Image_inspect
  | Image_list

type image_probe_failure =
  { phase : image_probe_phase
  ; status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; reason : string
  }

type image_probe_outcome =
  | Image_present
  | Image_missing
  | Image_cli_unavailable
  | Image_probe_failed of image_probe_failure

val classify_image_probe :
  inspect:Unix.process_status * string * string ->
  listing:(Unix.process_status * string * string) option ->
  image_probe_outcome
(** Classify [container image inspect] without reading human error prose.
    Successful inspect output must be a JSON array. Exit 1 is [Image_missing]
    only when a subsequent [container image list --format json] also succeeds
    with a JSON array, proving that the service and image store were readable.
    Every unavailable or malformed observation fails closed. *)

val image_probe : image:string -> timeout_sec:float -> image_probe_outcome
(** Run the structured probe and retain its typed outcome before the public
    sandbox boundary renders an operator-facing error. *)

(** Turn-container argv. Same lifecycle as the Docker turn lane: detached
    guest holding [tail -f /dev/null], commands by [exec], removed on
    [stop] via [--rm]. The playground is mounted here; everything else the
    guest may see arrives through [mount_args], which the caller builds --
    config, GitHub identity, secret files and [--env-file]. Workspace-state
    mounts and the /etc/passwd identity mounts remain absent.

    [mount_args] is passed in Docker's own spelling: measured 2026-08-28,
    container accepts [-v host:container:ro] and [--env-file] unchanged. *)

val turn_start_argv :
  container_name:string ->
  label_args:string list ->
  uid:int ->
  gid:int ->
  memory:string ->
  cpus:string option ->
  host_root:string ->
  container_root:string ->
  network_args:string list ->
  mount_args:string list ->
  image:string ->
  string list

val exec_argv :
  container_name:string ->
  uid:int ->
  gid:int ->
  container_cwd:string ->
  stdin:bool ->
  command_argv:string list ->
  string list

val stop_argv : container_name:string -> string list
(** [--rm] makes stop also remove; observed live 2026-08-28. *)

val delete_force_argv : container_name:string -> string list
(** For a guest that survived as stopped (e.g. the host rebooted out from
    under [--rm]); running guests are taken down with {!stop_argv}. *)

val keeper_vm_container_kind : string

val inspect_argv : container_name:string -> string list

val running_of_inspect_json : string -> (bool, string) result
(** [Ok true] iff [.[0].status.state = "running"]. The caller maps a
    non-zero inspect exit to absent before calling this. *)

val live_containers_of_json :
  base_path:string ->
  keeper_name:string ->
  Yojson.Safe.t ->
  (Keeper_sandbox_runtime.live_container list, string) result
(** Decode only the Apple Container guests labelled for this base path and
    keeper. Unrelated host containers are not projected into Keeper status. *)

val list_live_containers :
  base_path:string ->
  keeper_name:string ->
  timeout_sec:float ->
  (Keeper_sandbox_runtime.live_container list, string) result
(** Read the labelled Apple Container guest inventory for one microvm Keeper. *)

type sweep_candidate =
  { container_id : string
  ; keeper_name : string option
  ; owner_pid : int option
  }

type sweep_outcome =
  { removed : string list
  ; failed : (string * string) list
  }

val sweep_candidates_of_json :
  is_pid_alive:(int -> bool) -> Yojson.Safe.t -> sweep_candidate list
(** Guests in a [container list --format json] listing whose owning server is
    gone. A guest is keeper-lifetime, so age proves nothing; what marks one
    abandoned is its owner pid naming a process that no longer exists. A
    guest whose label is missing or unparseable is not a candidate -- this
    build cannot say whose it is, and removing a running guest to tidy up is
    worse than leaking one. *)

val sweep_abandoned_guests :
  command_available:(string -> bool) ->
  timeout_sec:float ->
  is_pid_alive:(int -> bool) ->
  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string) ->
  sweep_outcome option
(** Remove every abandoned guest, reporting what happened. Return [None]
    without spawning when the microVM CLI executable is absent. An unreadable
    listing removes nothing and returns [Some] with an empty outcome. *)
