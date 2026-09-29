(** A durable observation record for Board attention [Ready] confirmations.

    [Keeper_board_attention_partition.confirm_ready] re-appends the partition's
    own row to confirm the [Ready] state is on disk. That row is byte-identical
    to the one before it, so it carries no time and no process identity, and
    [recover_for_process_start] compacts the partition ledger to one row per
    partition at the next boot. A restart that confirmed the same generation
    therefore leaves no trace, and a reader cannot tell how many boots
    confirmed it.

    This module writes a separate append-only record, one row per confirmation,
    in a file the partition compaction never rewrites. It answers "which boot
    confirmed this generation, and when" without duplicating the partition's
    domain state or generation transitions, which stay in the partition ledger.

    The record is diagnostic. A failure to write it never fails the
    confirmation it describes: the partition ledger is the authority, and this
    file only says what the ledger cannot. *)

type confirm_outcome =
  | Appended  (** the confirmation advanced the partition state *)
  | Unchanged  (** the partition state was already what the confirmation asked for *)

type partition_write =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type record =
  { partition_id : string
  ; generation : int
  ; keeper_name : string
  ; boot_identity : string
  ; observed_at : float
  ; confirm_outcome : confirm_outcome
  ; partition_write : partition_write
  }

val schema : string
(** The record's schema tag, written as the [schema] field of every row. *)

val path : base_path:string -> keeper_name:string -> string
(** The record file for one Keeper. Separate from the partition ledger, so
    {!Keeper_board_attention_partition.recover_for_process_start}'s compaction
    cannot rewrite it. *)

val record_to_yojson : record -> Yojson.Safe.t
val record_of_yojson : Yojson.Safe.t -> (record, string) result

val append :
  base_path:string ->
  keeper_name:string ->
  partition_id:string ->
  generation:int ->
  observed_at:float ->
  confirm_outcome:confirm_outcome ->
  partition_write:partition_write ->
  (unit, string) result
(** Append one confirmation record. The caller must have already committed the
    partition row this record names: a record for a confirmation the partition
    ledger does not hold would be a false observation. A failure here is
    reported to the caller, which logs it and keeps the confirmation's own
    result. *)

val read : base_path:string -> keeper_name:string -> (record list, string) result
(** Every record for one Keeper, oldest first. A missing file is the empty
    list. Used by the restart measurement and by tests. *)
