(** The latest ext4 state the server read for each Keeper volume
    (RFC keeper-volume-filesystem-repair §3.2).

    The superblock is the authority. This is a process-local projection of
    the last read, kept so a Keeper status read shows the state without
    spawning the [container] CLI. A server start begins with no observation. *)

type failure =
  | Inspect_refused of string
      (** [container volume inspect] failed or did not name an ext4 image. *)
  | Image_unreadable of Keeper_volume_filesystem.read_failure

type observation =
  { volume : string
  ; observed_at : float
  ; source : string option  (** Host path of the image that was read. *)
  ; result : (Keeper_volume_filesystem.state, failure) result
  }

val volumes_of_meta : Keeper_meta_contract.keeper_meta -> string list
(** The volumes an image-backed Keeper owns: the work and build volumes of a
    [Micro_vm] Keeper on [Apple_container]. Other profiles and backends keep
    their tree in host directories, which have no superblock to read. *)

val observe :
  now:float ->
  inspect:(volume:string -> (Yojson.Safe.t, string) result) ->
  read_image:
    (path:string ->
     (Keeper_volume_filesystem.state, Keeper_volume_filesystem.read_failure) result) ->
  volume:string ->
  observation option * observation
(** Read the volume's image, record the read as the latest, and return the
    previous latest beside it. The image path from the last good read is
    reused; [inspect] runs for the first read and after a failed one. *)

val latest : volume:string -> observation option

val damage_appeared : previous:observation option -> observation -> bool
(** The read records errors and the previous one did not, or there was none
    since this server started. *)

val observation_to_yojson : observation -> Yojson.Safe.t
val failure_to_string : failure -> string
