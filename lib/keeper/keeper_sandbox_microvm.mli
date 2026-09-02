(** Apple [container] argv for the [Micro_vm] sandbox profile.

    Command construction only: nothing here starts a VM. Dispatch does --
    [Keeper_turn_sandbox_runtime] boots and adopts the guest, and the remote
    lane ([Keeper_sandbox_remote]) drives its shim over [container exec].
    The guest owns its working tree on a per-keeper volume (RFC-0400); the
    host playground is never mounted into it. See the implementation for the
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

(** Guest boot argv. Same lifecycle as the Docker persistent lane: detached
    guest holding [tail -f /dev/null], commands by [exec], removed on
    [stop] via [--rm]. Nothing of the host playground is mounted; everything
    the guest may see arrives through [mount_args], which the caller builds
    -- config, GitHub identity, the work volume and the shim. The working
    directory is {!work_volume_guest_root}. Workspace-state mounts and the
    /etc/passwd identity mounts remain absent.

    [mount_args] is passed in Docker's own spelling: measured 2026-08-28,
    container accepts [-v host:container:ro] and [--env-file] unchanged. *)

val turn_start_argv :
  container_name:string ->
  label_args:string list ->
  uid:int ->
  gid:int ->
  memory:string ->
  cpus:string option ->
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

(** {2 The work volume and the shim (RFC-0400)}

    The keeper's working tree lives on a per-keeper ext4 volume mounted at
    {!work_volume_guest_root}; that path is the remote lane's [remote_root]
    for the guest. A tree on the virtiofs share pins one host file
    descriptor -- one host vnode -- per inode the guest touches against a
    [kern.maxvnodes] of 263,168; measured writing 20,000 files on container
    1.3.1: ext4 volume 26 -> 26 host descriptors, virtiofs 26 -> 20,027.
    See the implementation for the panics this prevents. The static
    [masc-exec-shim] and its config travel in one host directory mounted
    read-only at {!shim_guest_dir}. *)

val work_volume_guest_root : string

(** [masc-keeper-work-<keeper_name>], or an error when the name carries
    anything outside [A-Za-z0-9._-]. *)
val work_volume_name : keeper_name:string -> (string, string) result

val volume_create_argv : volume_name:string -> size:string -> string list
val work_volume_mount_args : volume_name:string -> string list

val keeper_work_root : keeper_name:string -> string
(** [<work root>/<sanitized keeper>]: what the shim jails requests under. *)

val shim_guest_dir : string
val shim_binary_name : string
val shim_config_name : string
val shim_guest_path : string
val shim_config_guest_path : string
val shim_mount_args : host_dir:string -> string list

val shim_config_content : payload_path:string -> string
(** [remote_root=<work root>], [path=<payload_path>] and
    [env_allowlist=<config env names>]: the lines the guest's shim reads. *)

val remote_env_allowlist : string list
val remote_connect_timeout_sec : int
val remote_max_concurrent_sessions : int

(** Volume ids in a [container volume list --format json] payload. *)
val volume_names_of_json : Yojson.Safe.t -> (string list, string) result

type volume_probe_outcome =
  | Volume_present
  | Volume_absent
  | Volume_probe_failed of string

(** [container volume inspect] exits 1 for "no such volume" and also for a
    stopped container system, so a 1 is confirmed against the listing instead
    of being read as absence -- creating over an existing volume would land on
    a keeper's working tree. Pure, so the ambiguity is testable. *)
val classify_volume_probe
  :  volume_name:string
  -> inspect:Unix.process_status * string * string
  -> listing:(Unix.process_status * string * string) option
  -> volume_probe_outcome

val volume_probe : volume_name:string -> timeout_sec:float -> volume_probe_outcome

(** Create the work volume when absent. [container volume create] is not
    idempotent, so existence is settled by the probe rather than by reading
    its "already exists" message. Error codes are [microvm_work_volume_*]. *)
val ensure_work_volume
  :  volume_name:string
  -> size:string
  -> timeout_sec:float
  -> ([ `Created | `Already_present ], string) result

val keeper_work_root_mkdir_argv : container_name:string -> keeper_name:string -> string list
(** Create {!keeper_work_root} inside the guest, in one exec. The host
    cannot: the directory lives inside the volume's ext4 image. The volume
    root is initially root-owned and the user namespace refuses a later
    chmod, so creation runs as root with an explicit writable mode that
    applies only to a new directory. Idempotent. *)

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
  base_path:string ->
  is_pid_alive:(int -> bool) -> Yojson.Safe.t -> sweep_candidate list
(** Guests in a [container list --format json] listing that belong to this
    base path and whose owning server is gone. A guest whose scope or owner
    label is missing or unparseable is not a candidate. *)

val sweep_abandoned_guests :
  base_path:string ->
  command_available:(string -> bool) ->
  timeout_sec:float ->
  is_pid_alive:(int -> bool) ->
  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string) ->
  sweep_outcome option
(** Remove every abandoned guest, reporting what happened. Return [None]
    without spawning when the microVM CLI executable is absent. An unreadable
    listing removes nothing and returns [Some] with an empty outcome. *)
