(** Keeper docker-routed read execution.

    RFC-0006 Phase B-2: when [MASC_KEEPER_SYMMETRIC_SANDBOX] and
    [MASC_KEEPER_DOCKER_READ] are both true and the keeper has a
    hardened sandbox profile, read-side operations route through
    [docker run --rm <image> cat <container_path>] so the container's
    mount restrictions are the load-bearing boundary instead of a
    host-side string check.

    The host-side containment check from Phase B-1 remains as
    defense in depth and is still applied before this module is
    consulted. *)

(** [should_route_read ~meta] is [true] iff this keeper's reads
    should go through docker. Encapsulates the (sandbox_profile,
    env flag) triplet so callers do not have to repeat it. *)
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
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  host_path:string ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, string) result
