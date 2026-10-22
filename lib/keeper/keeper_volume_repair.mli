(** One repair of a Keeper volume that recorded ext4 errors, and its receipt
    (RFC keeper-volume-filesystem-repair §3.3).

    The caller holds the Keeper's maintenance lane, so no turn boots a guest
    while {!repair} runs. {!repair} stops before touching anything when the
    helper image is unknown or a backup already exists, then removes the
    Keeper's guests, reads the superblock with no guest attached, clones the
    image, runs the e2fsck helper and reads the superblock again: that last
    read, not the helper's exit codes, decides the outcome. The effects are
    arguments so the flow can be checked without a runtime. *)

type outcome =
  | Helper_unavailable of string  (** No helper image; nothing was touched. *)
  | Backup_present
      (** A backup is already beside the image. The operator owns it, so
          nothing was touched. *)
  | Teardown_refused of string  (** The Keeper's guests could not be removed. *)
  | Not_needed  (** With no guest attached, the superblock was clean. *)
  | Unreadable_before of Keeper_volume_filesystem.read_failure
  | Backup_unavailable of string  (** The clone failed; nothing was repaired. *)
  | Helper_refused of string
      (** A stale helper could not be removed, or the helper stopped before
          e2fsck ran (for example the volume stayed mounted, or the operator
          stopped it). *)
  | Repaired  (** The superblock is clean after e2fsck. *)
  | Repair_incomplete of
      { count : int
      ; first : Keeper_volume_filesystem.error_site option
      ; last : Keeper_volume_filesystem.error_site option
      }  (** The superblock still records errors after e2fsck. *)
  | Unreadable_after of Keeper_volume_filesystem.read_failure

type receipt =
  { repair_id : string
  ; keeper : string
  ; volume : string
  ; image : string
  ; started_at : float
  ; finished_at : float
  ; before :
      (Keeper_volume_filesystem.state, Keeper_volume_filesystem.read_failure) result option
      (** The read after teardown; [None] when the repair stopped earlier. *)
  ; backup : string option  (** The clone made before e2fsck. *)
  ; helper_status : string option  (** Exit status of the helper, when it ran. *)
  ; helper_output : string option  (** The helper's stdout and stderr, uncut. *)
  ; outcome : outcome
  }

type helper_run = unit -> (Unix.process_status * string * string, string) result

val backup_path : image:string -> string
(** The one backup kept per volume, beside its image. *)

val clone_image : source:string -> target:string -> (unit, string) result
(** {!Fs_compat.clone_file}: a copy-on-write clone or an [Error], never a
    data copy that could fill the host disk. Blocking. *)

val repair :
  now:(unit -> float) ->
  repair_id:string ->
  helper:(helper_run, string) result ->
  backup_exists:(path:string -> bool) ->
  teardown:(unit -> (unit, string) result) ->
  read_image:
    (path:string ->
     (Keeper_volume_filesystem.state, Keeper_volume_filesystem.read_failure) result) ->
  clone:(source:string -> target:string -> (unit, string) result) ->
  keeper:string ->
  volume:string ->
  image:string ->
  receipt
(** [helper] is [Error] when no helper image could be resolved. *)

val outcome_to_string : outcome -> string
val outcome_to_yojson : outcome -> Yojson.Safe.t
val receipt_to_yojson : receipt -> Yojson.Safe.t

val receipt_path : masc_dir:string -> keeper:string -> repair_id:string -> string
(** [<masc dir>/keeper-volume-repairs/keeper-<sha256 keeper>/<repair id>.json]. *)

val write_receipt : masc_dir:string -> receipt -> (string, string) result
(** Write the receipt atomically and return its path. *)
