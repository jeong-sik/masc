(** Keeper docker-routed read execution.

    RFC-0006 Phase B-2: hardened keepers route read-side operations
    through [docker run --rm <image> cat <container_path>] so the
    container's mount restrictions are the load-bearing boundary
    instead of a host-side string check.

    The host-side containment check from Phase B-1 remains as
    defense in depth and is still applied before this module is
    consulted. *)

(** [should_route_read ~meta] is [true] iff this keeper's reads
    should go through docker. Encapsulates the
    [sandbox_profile=docker] policy so callers do not have to repeat
    it. *)
val should_route_read : meta:Keeper_types.keeper_meta -> bool

(** [container_path_of_host ~config ~meta ~host_path] maps a
    host-side absolute playground path to its in-container
    counterpart. Returns [Error _] when [host_path] is not inside the
    keeper's playground bundle (programmer error — caller should have
    run the containment check first). *)
val container_path_of_host :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  host_path:string ->
  (string, string) result

(** [read_file_in_container ~config ~meta ~host_path ~max_bytes
    ~timeout_sec ()] runs [docker run --rm <image> cat
    <container_path>] with the keeper's playground mounted read-only
    and returns the captured bytes (clamped to [max_bytes]).

    Errors include image misconfiguration, docker exit non-zero, or
    the input not being inside the playground. *)
val read_file_in_container :
  ?turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  host_path:string ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, string) result

(** [run_command_in_container ~config ~meta ~command_argv ~max_bytes
    ~timeout_sec ()] is the general-purpose primitive that
    [read_file_in_container] is built on. It runs the same hardened
    docker prelude (read-only rootfs, no caps, no network, playground
    mounted read-only at [Keeper_sandbox.container_root meta.name])
    and appends [command_argv] as the program + arguments executed
    inside the container.

    The caller owns container-path translation: any path referenced
    in [command_argv] must already be in container space (use
    [container_path_of_host] to convert). The first element of
    [command_argv] is the executable.

    Returns the captured stdout bytes clamped to [max_bytes]. Errors
    include image misconfiguration, empty [command_argv], runtime
    preflight failure, and docker exit non-zero. The error tag uses
    the program name (e.g. [docker_rg_failed], [docker_cat_failed])
    for caller log forensics. *)
val run_command_in_container_with_status :
  ?turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t ->
  ?ok_exit_codes:int list ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (Unix.process_status * string, string) result

(** [run_command_in_container ?ok_exit_codes ~config ~meta ~command_argv
    ~max_bytes ~timeout_sec ()] is a convenience wrapper around
    [run_command_in_container_with_status] that drops the returned
    process status and keeps only the captured stdout bytes. *)
val run_command_in_container :
  ?turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t ->
  ?ok_exit_codes:int list ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, string) result
