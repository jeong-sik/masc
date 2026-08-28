(** Apple [container] argv for the [Micro_vm] sandbox profile.

    Command construction only: nothing here starts a VM, and dispatch still
    refuses [Micro_vm]. See the implementation for the measured cost of the
    backend and for the two Docker hardening flags [container run] does not
    accept. *)

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

(** Turn-container argv. Same lifecycle as the Docker turn lane: detached
    guest holding [tail -f /dev/null], commands by [exec], removed on
    [stop] via [--rm]. A microvm turn mounts the playground and nothing
    else — no secret projection, no GitHub identity, no config or
    workspace-state mounts; keepers needing those stay on [Docker]. *)

val turn_start_argv :
  container_name:string ->
  label_args:string list ->
  uid:int ->
  gid:int ->
  memory:string ->
  host_root:string ->
  container_root:string ->
  network_args:string list ->
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
