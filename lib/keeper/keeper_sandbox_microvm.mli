(** microVM argv for the [Micro_vm] sandbox profile.

    Command construction only: nothing here starts a VM. Dispatch does --
    [Keeper_turn_sandbox_runtime] boots and adopts the guest, and the remote
    lane ([Keeper_sandbox_remote]) drives its shim over the guest's exec.
    The guest owns its working tree on a per-keeper volume (RFC-0400); the
    host playground is never mounted into it.

    Every builder takes the runtime the keeper declared. A surface that took
    the runtime only on teardown pointed a keeper's boot and its cleanup at
    two different CLIs, which is #32837. See the implementation for the
    measured cost of the Apple backend and for the Docker hardening flags
    each runtime does not accept. *)

val command_argv_for : Keeper_microvm_backend.t -> string list
(** The CLI prefix for one backend. *)

val unsupported_docker_flags : string list
(** Docker hardening flags [container run] rejects. [container] errors on an
    unknown option rather than ignoring it, so this list is what a reader
    must weigh when choosing the profile, not a runtime fallback. *)

val policy_network_name : string
(** The host-only network a [Network_policy] guest is attached to. It carries
    no allowlist of its own: it removes every route except the host gateway,
    and the keeper's allowlist is judged by the proxy behind that gateway. *)

val policy_network_create_argv_for : Keeper_microvm_backend.t -> (string list, string) result
(** Create the host-only network the policy lane attaches to. Only the
    backend that carries the lane answers; the others refuse, so a backend
    that gained a policy arm without gaining this fails here rather than
    booting a guest onto a network nobody created. *)

val policy_network_list_argv_for : Keeper_microvm_backend.t -> (string list, string) result
(** List networks, to see whether {!policy_network_name} already exists. *)

val policy_network_present : listing:string -> (bool, string) result
(** Whether [container network list --format json] carries
    {!policy_network_name}. Compared as a decoded [id], so nothing depends on
    how the CLI spaces a column, and a network whose name contains this one's
    cannot answer for it.

    Unparseable output is an error rather than "absent": reading a failed
    decode as absence would drive a create against a network that may already
    exist, and the guest would then be refused with a message about creation
    rather than about the listing that could not be read. *)

val policy_network_inspect_argv_for : Keeper_microvm_backend.t -> (string list, string) result
(** Inspect the policy network, to learn the gateway a guest on it reaches
    the host at. *)

val policy_network_gateway : inspect:string -> (string, string) result
(** The [status.ipv4Gateway] of the inspected network.

    Read rather than assumed: container assigns the subnet when the network
    is created, so a compiled-in address would be right only until a host had
    a network already on it. Absent or unparseable output is an error, not a
    fallback -- a guest handed the wrong gateway reaches nothing and says
    nothing about why. *)

type policy_proxy =
  { gateway : string
  ; port : int
  }
(** Where a policy guest's one route is: the gateway it sees the host at, and
    the port its keeper's proxy bound. Both are discovered at boot -- the
    gateway from the network, the port from the listener -- so neither is a
    constant. *)

val network_args_for :
  Keeper_microvm_backend.t ->
  dns:string option ->
  policy_proxy:policy_proxy option ->
  Keeper_types_profile_sandbox.network_mode ->
  (string list, string) result
(** How one runtime is told to close or open the guest's network.

    A closed network is an isolation property, so the spelling is per runtime
    rather than one grammar sent to all three. [container] and [nerdctl] take
    Docker's [--network none] and [--dns]; [Network_inherit] there is
    container's NAT, which routes outside and needs a nameserver passed in
    (the guest's resolver points at the gateway and the gateway refuses DNS
    from inside, so without one the guest routes fine and resolves nothing).

    [msb] rejects both Docker spellings and has its own: [Network_none] is
    [--no-net]. [Network_inherit] is [Error] rather than an empty argv --
    msb's network with no flag has not been measured, and an omission would
    be a guess at how open the guest is. *)

val image_present_for :
  Keeper_microvm_backend.t -> image:string -> timeout_sec:float -> (unit, string) result
(** Gate the run on the image already being in this runtime's own store.
    None of the three has a [--pull=never]: without this, a missing image is
    fetched from a registry rather than refused. The refusal names the CLI
    that was asked, so an [msb] keeper is not told to install Apple's. *)

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

type json_shape =
  | Json_array
      (** One array of records: [container image list --format json],
          [container image inspect], [msb image list --format json],
          [nerdctl image inspect --mode dockercompat]. *)
  | Json_object
      (** One bare object: [msb image inspect --format json], which answers a
          record rather than the array of one Docker's grammar returns. *)
  | Json_lines
      (** One JSON object per line: [nerdctl images] with a Go template. *)

val image_listing_shape_for : Keeper_microvm_backend.t -> json_shape
(** Which shape this runtime's image listing arrives in. Reading a line
    stream with the array check would call a healthy listing malformed and
    turn "the image is missing" into "the probe could not say". *)

val image_listing_argv_for : Keeper_microvm_backend.t -> string list
(** The listing that proves this runtime's image store was readable.
    [image list --format json] for [container] and [msb]; [images] with a Go
    template for [nerdctl], which has no [image list] subcommand. *)

val image_inspect_shape_for : Keeper_microvm_backend.t -> json_shape
(** Which shape this runtime answers a single-image inspect in. [msb] answers
    an object where the other two answer an array of one; reading its answer
    with the array check reports [Image_probe_failed] for an image that is
    present, which is the inverse of what the probe is for. *)

val image_inspect_argv_for : Keeper_microvm_backend.t -> image:string -> string list
(** The single-image inspect, in the machine form each CLI documents.
    [container image inspect] answers JSON with no flag; [msb image inspect]
    answers a human table unless given [--format json]; [nerdctl image
    inspect] documents [--mode=(dockercompat|native)] and no default, so the
    mode is named. *)

val classify_image_probe :
  inspect_shape:json_shape ->
  listing_shape:json_shape ->
  inspect:Unix.process_status * string * string ->
  listing:(Unix.process_status * string * string) option ->
  image_probe_outcome
(** Classify an image inspect without reading human error prose. Successful
    inspect output must parse in [inspect_shape]. Exit 1 is [Image_missing]
    only when a subsequent image listing also succeeds in [listing_shape],
    proving that the runtime and its image store were readable. Every
    unavailable or malformed observation fails closed. *)

val image_probe_for :
  Keeper_microvm_backend.t -> image:string -> timeout_sec:float -> image_probe_outcome
(** Run the structured probe against one runtime and retain its typed outcome
    before the public sandbox boundary renders an operator-facing error. *)

type constraint_refusal =
  { guest_constraint : Keeper_microvm_backend.guest_constraint
  ; reason : string
  }

val constraint_refusals_message :
  Keeper_microvm_backend.t -> constraint_refusal list -> string
(** One [microvm_constraint_unexpressible:] line naming the runtime and every
    guarantee it could not spell, with each runtime's own reason. No cap and
    no "and N more": a boot refusal an operator has to guess the rest of is
    the reason the guarantee was silently dropped before. *)

val turn_start_argv_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  label_args:string list ->
  uid:int ->
  gid:int ->
  memory:string ->
  cpus:string option ->
  network_args:string list ->
  mount_args:string list ->
  image:string ->
  constraints:Keeper_microvm_backend.guest_constraint list ->
  (string list, constraint_refusal list) result
(** Guest boot argv, or the guarantees this runtime cannot express.

    Same lifecycle as the Docker persistent lane: detached guest holding
    [tail -f /dev/null], commands by [exec]. Nothing of the host playground
    is mounted; everything the guest may see arrives through [mount_args],
    which the caller builds -- config, GitHub identity, the work volume and
    the shim. The working directory is {!work_volume_guest_root}.
    Workspace-state mounts and the /etc/passwd identity mounts remain absent.

    [constraints] are asked for by name. An [Isolation] guarantee this
    runtime has no flag for makes the whole call [Error]: booting without it
    would hand the keeper a weaker sandbox than the profile it declared, and
    nothing in the argv would say so. A [Lifecycle] one is recorded on the
    guest as a [masc.mcp.microvm_dropped] label and the boot continues,
    because teardown removes the guest explicitly either way.

    The booted guest also carries [masc.mcp.microvm_backend], so a listing
    can tell which runtime it came from without reading the keeper's TOML. *)

val exec_argv_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  uid:int ->
  gid:int ->
  container_cwd:string ->
  stdin:bool ->
  command_argv:string list ->
  string list
(** One command inside a running guest. [msb] needs [--] between the guest
    name and the command and spells stdin [--stream]; the other two take the
    command bare with [-i]. *)

val shim_exec_prefix_for :
  Keeper_microvm_backend.t ->
  container_name:string ->
  uid:int ->
  gid:int ->
  remote_root:string ->
  shim_config_path:string ->
  (string list, string) result
(** The prefix the remote lane delivers a framed request through, ending at
    the guest name so the caller appends the shim path.

    The prefix carries the config location and the identity the shim runs
    under. All three CLIs document the environment entry the first needs
    ([msb exec] has [-e, --env]).

    [Error] for [msb]: [container exec --user] documents [name|uid[:gid]] and
    nerdctl takes Docker's, but [msb exec --user] documents a guest user name
    and no numeric form (0.6.16), so the mapped [uid:gid] a keeper's commands
    run as cannot be named. Sending it would either be rejected or resolved
    as somebody else's user name, writing to the keeper's tree as that user.
    Naming a guest user for the lane is the change that would settle it,
    which is a decision about identity rather than a spelling. *)

val stop_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> string list

val delete_force_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> string list
(** For a guest that survived as stopped (e.g. the host rebooted out from
    under a remove-on-exit flag); running guests are taken down with
    {!stop_argv_for}. *)

val logs_tail_argv_for :
  Keeper_microvm_backend.t -> tail:int -> container_id:string -> string list
(** The last [tail] lines of a guest's stdio. [container] takes [-n]; [msb]
    rejects [-n] and takes [--tail], and [nerdctl] documents both. *)

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

val apple_volume_create_argv : volume_name:string -> size:string -> string list
(** Apple's sized-volume spelling. Named after the runtime rather than left
    as the lane's default: [msb] rejects [-s] and wants [--kind disk --size],
    and [nerdctl volume create] documents no size flag at all.
    {!ensure_work_volume_for} is the entry that answers for all three. *)

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

val apple_volume_probe :
  volume_name:string -> timeout_sec:float -> volume_probe_outcome

(** Create the work volume when absent, for whichever runtime the keeper
    declared. [container volume create] is not idempotent, so existence is
    settled by the probe rather than by reading its "already exists" message.

    Only Apple's grammar is established. [msb] and [nerdctl] return an
    [Error] naming what is missing rather than a guess: for [msb] the create
    is known and the inspect and list that settle existence are not, and
    creating over a volume that already holds a keeper's tree is exactly what
    that check exists to prevent; for [nerdctl] there is no size flag to
    establish. Error codes are [microvm_work_volume_*]. *)
val ensure_work_volume_for
  :  Keeper_microvm_backend.t
  -> volume_name:string
  -> size:string
  -> timeout_sec:float
  -> ([ `Created | `Already_present ], string) result

val keeper_work_root_mkdir_argv_for :
  Keeper_microvm_backend.t -> container_name:string -> keeper_name:string -> string list
(** Create {!keeper_work_root} inside the guest, in one exec. The host
    cannot: the directory lives inside the volume's ext4 image. The volume
    root is initially root-owned and the user namespace refuses a later
    chmod, so creation runs as root with an explicit writable mode that
    applies only to a new directory. Idempotent. *)

val keeper_work_root_write_probe_argv_for
  :  Keeper_microvm_backend.t
  -> container_name:string
  -> uid:int
  -> gid:int
  -> keeper_name:string
  -> string list
(** Create and remove a temporary file in {!keeper_work_root} as [uid:gid],
    the identity the keeper's commands run under. Exit 0 proves the keeper
    can write its root; any other exit carries the root's owner and mode on
    stderr. A root that exists but belongs to another uid -- a tree imported
    from elsewhere -- fails here rather than on the keeper's first Write. *)

val work_volume_mounted_probe_argv_for
  :  Keeper_microvm_backend.t
  -> container_name:string
  -> string list
(** Boot invariant (RFC-0052): exit 0 only when {!work_volume_guest_root} is a
    mountpoint inside the guest, read from [/proc/mounts] as root.

    Runs before the mkdir and the write probe above because neither can tell
    a mounted volume from a writable directory on the guest rootfs: with the
    mount absent both succeed, and the guest then serves an ephemeral tree
    whose writes evaporate on the next boot while every log line names the
    volume. [grep -F] (fixed string) over [/proc/mounts] rather than
    [mountpoint(1)], which the sandbox image does not ship; the pattern
    carries the mountpoint field's surrounding spaces so a prefix of the path
    cannot match. *)

val keeper_vm_container_kind : string

val inspect_argv_for
  :  Keeper_microvm_backend.t
  -> container_name:string
  -> string list
(** The argv that makes this backend report a guest's state in the shape
    {!running_of_inspect_json_for} parses. *)

val running_of_inspect_json_for
  :  Keeper_microvm_backend.t
  -> string
  -> (bool, string) result
(** Whether the guest this backend describes is running.

    Each backend owns its own parse: [container inspect] answers a list whose
    first element nests [status.state], [msb inspect --format json] a flat
    object whose [status] is capitalised. A shape the chosen parser does not
    recognise is [Error]. It is never [Ok false] -- read as "not running", an
    unrecognised answer takes a live guest down and boots a second beside
    it. *)

val live_containers_of_json :
  base_path:string ->
  keeper_name:string ->
  Yojson.Safe.t ->
  (Keeper_sandbox_runtime.live_container list, string) result
(** Decode only the guests labelled for this base path and keeper out of a
    [Labelled_json_array] listing. Unrelated host containers are not
    projected into Keeper status. *)

type container_listing =
  | Labelled_json_array of string list
      (** The argv whose output nests [configuration.labels], which is where
          the base path hash, the keeper name and the owner pid live. *)
  | Listing_not_established of string
      (** Why this runtime's listing cannot be scoped to a base path and
          keeper. Named rather than answered with the Apple argv: read as "no
          guests", an unscopable listing is the answer that leaves a guest
          running with nothing able to reap it. *)

val container_listing_for : Keeper_microvm_backend.t -> container_listing
(** [Labelled_json_array] for [container list -a --format json].
    [Listing_not_established] for [msb], whose listing rows carry no labels
    (they live in [msb inspect] under [active_config.labels]), and for
    [nerdctl], which has no [list] subcommand and no literal [--format
    json]. *)

val list_live_containers_for :
  Keeper_microvm_backend.t ->
  base_path:string ->
  keeper_name:string ->
  timeout_sec:float ->
  (Keeper_sandbox_runtime.live_container list, string) result
(** Read the labelled guest inventory for one microvm Keeper.
    [microvm_container_listing_unsupported] when this runtime's listing
    cannot be scoped, rather than an empty inventory that reads as "none". *)

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
(** Guests in a [Labelled_json_array] listing that belong to this base path
    and whose owning server is gone. A guest whose scope or owner label is
    missing or unparseable is not a candidate. *)

val sweep_abandoned_guests :
  base_path:string ->
  command_available:(string -> bool) ->
  timeout_sec:float ->
  is_pid_alive:(int -> bool) ->
  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string) ->
  (Keeper_microvm_backend.t * sweep_outcome) list
(** Remove every abandoned guest, per runtime, reporting what happened.

    No keeper is in scope here and none should be: a guest this process did
    not boot belongs to a keeper this process may not have. What is in scope
    is the set of runtimes, so each is asked for its own guests with its own
    argv and removed with its own removal spelling. A runtime whose CLI is
    absent, or whose listing cannot be scoped to a base path, contributes no
    row -- so an empty list means nothing was swept, not that nothing was
    found. An unreadable listing removes nothing and contributes an empty
    outcome. *)
