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
  Keeper_types_profile_sandbox.network_mode -> (string list, string) result
(** [Network_inherit] is refused: container has no host network and its
    default network does not route outside, so honouring it silently would
    leave the keeper with no route while its profile still claimed one. *)

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
