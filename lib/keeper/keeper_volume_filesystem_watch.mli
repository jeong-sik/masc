(** The latest ext4 state the server read for each Keeper volume
    (RFC keeper-volume-filesystem-repair §3.2).

    The superblock is the authority. This is a process-local projection of
    the last read, kept so a Keeper status read shows the state without
    spawning the [container] CLI. A server start begins with no observation. *)

(** What a volume holds. The build volume is recreated on every fresh guest
    boot; the work volume keeps the Keeper's tree across boots. *)
type volume_kind =
  | Work
  | Build

type volume =
  { name : string
  ; kind : volume_kind
  }

type failure =
  | Inspect_refused of string
      (** [container volume inspect] failed or printed no JSON. *)
  | Inspect_unparsed of Keeper_volume_filesystem.inspect_failure
  | Image_unreadable of
      { source : string
      ; failure : Keeper_volume_filesystem.read_failure
      }

type reading =
  { source : string  (** Host path of the image that was read. *)
  ; state : Keeper_volume_filesystem.state
  }

type observation =
  { volume : string
  ; observed_at : float
  ; result : (reading, failure) result
  }

val volumes_of_meta : Keeper_meta_contract.keeper_meta -> volume list
(** The volumes an image-backed Keeper owns: the work and build volumes of a
    [Micro_vm] Keeper on [Apple_container]. Other profiles and backends keep
    their tree in host directories, which have no superblock to read.
    [meta] must be effective: see {!volumes_of_durable_meta}. *)

val volumes_of_durable_meta :
  base_path:string -> Keeper_meta_contract.keeper_meta -> (volume list, string) result
(** {!volumes_of_meta} after the Keeper's TOML is overlaid. Durable meta (a
    persisted snapshot, the Owner projection) carries a placeholder
    [sandbox_profile], so {!volumes_of_meta} on it finds no volume. [Error]
    is an invalid Keeper profile. *)

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

val source : observation -> string option
(** The image path the observation read or failed to read; [None] when the
    volume inspect itself failed. *)

val damage_appeared : previous:observation option -> observation -> bool
(** The read records errors and the previous one did not, or there was none
    since this server started. *)

val observation_fields : observation -> (string * Yojson.Safe.t) list
val observation_to_yojson : observation -> Yojson.Safe.t
val failure_to_string : failure -> string
