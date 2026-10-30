(** One repair of a Keeper volume that recorded ext4 errors, and its receipt
    (RFC keeper-volume-filesystem-repair §3.3).

    The caller holds the Keeper's maintenance lane, so no turn boots a guest
    while {!repair} runs.

    A work volume keeps the Keeper's tree, so it is repaired: {!repair}
    stops before touching anything when the helper image is unknown or a
    backup already exists, then removes the Keeper's guests, reads the
    superblock with no guest attached, clones the image, runs the e2fsck
    helper and reads the superblock again. Once the helper has started, that
    last read, not the helper's exit status, decides the outcome.

    A build volume is recreated on every fresh guest boot, so removing the
    guests is the whole fix: nothing is cloned or checked.

    The effects are arguments so the flow can be checked without a runtime. *)

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
      (** The helper did not start (a stale helper could not be removed), or
          it stopped with a nonzero status and the superblock still records
          errors: the volume stayed mounted, or the operator stopped it. *)
  | Repaired  (** The superblock is clean after the helper ran. *)
  | Repair_incomplete of
      { count : int
      ; first : Keeper_volume_filesystem.error_site option
      ; last : Keeper_volume_filesystem.error_site option
      }  (** e2fsck ran to the end and the superblock still records errors. *)
  | Unreadable_after of Keeper_volume_filesystem.read_failure
  | Recreated_at_next_boot
      (** A build volume: the guests were removed, and the next boot deletes
          and recreates the volume. *)

type receipt =
  { repair_id : string
  ; keeper : string
  ; volume : string
  ; kind : Keeper_volume_filesystem_watch.volume_kind
  ; image : string
  ; started_at : float
  ; finished_at : float
  ; before :
      (Keeper_volume_filesystem.state, Keeper_volume_filesystem.read_failure) result option
      (** The read after teardown; [None] when the repair stopped earlier. *)
  ; backup : string option  (** The clone made before e2fsck. *)
  ; helper_status : string option  (** Exit status of the helper, when it ran. *)
  ; helper_output : string option
        (** The helper's stdout and stderr as the process runner captured
            them: the first 8 MiB and the last 256 KiB of each stream, with a
            marker where bytes were left out. *)
  ; helper_cleanup : string option
        (** Why the helper could not be removed after it ran, if it could not. *)
  ; outcome : outcome
  }

type helper_finished =
  { status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; cleanup : (unit, string) result  (** Removing the helper after it ran. *)
  }

type helper_run = unit -> (helper_finished, string) result
(** [Error] means the helper never started. *)

val backup_path : image:string -> string
(** The one backup kept per work volume, beside its image. *)

val clone_image : source:string -> target:string -> (unit, string) result
(** {!Fs_compat.clone_file}: a copy-on-write clone of a regular file or an
    [Error], never a data copy that could fill the host disk. Blocking. *)

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
  volume:Keeper_volume_filesystem_watch.volume ->
  image:string ->
  receipt
(** [helper] is [Error] when no helper image could be resolved. A build
    volume calls only [teardown]. *)

val outcome_to_string : outcome -> string
val outcome_to_yojson : outcome -> Yojson.Safe.t
val receipt_to_yojson : receipt -> Yojson.Safe.t

val receipt_path : masc_dir:string -> keeper:string -> repair_id:string -> string
(** [<masc dir>/keeper-volume-repairs/keeper-<sha256 keeper>/<repair id>.json]. *)

val write_receipt : masc_dir:string -> receipt -> (string, string) result
(** Write the receipt atomically and return its path. *)
