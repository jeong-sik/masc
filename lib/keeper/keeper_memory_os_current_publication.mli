(** The publication receipt and its recovery: the publication phase and the
    receipt with their JSON encoder, decoder and parse, the preflight and boot
    observations of a snapshot file with their inspection, the quarantine of a
    regular path, the read, write and remove of the receipt file, the check of
    the publication companions, the journal records of a publication, and the
    dispatch and recovery of a pending publication.

    [Keeper_memory_os_current] includes this module. *)

type publication_phase = Publication_prepared | Notification_pending

type publication_receipt =
  { phase : publication_phase
  ; prior : (int * string) option
  ; target_revision : int
  ; target_sha256 : string
  ; journal : Yojson.Safe.t
  }

type preflight_observation =
  | Preflight_absent
  | Preflight_snapshot
  | Preflight_publication_pending

val preflight_file :
  ?allow_missing_ancestors:bool -> string -> (string option, string) result

val quarantine_regular_path : string -> (unit, string) result

val read_publication :
  keepers_dir:string ->
  keeper_id:string -> (publication_receipt option, string) result

val inspect_for_preflight :
  keepers_dir:string -> keeper_id:string -> (preflight_observation, string) result

type boot_observation =
  | Boot_absent
  | Boot_readable
  | Boot_undecodable of { rejection : string; snapshot_sha256 : string }
  | Boot_unreadable of { detail : string }

val inspect_for_boot : keepers_dir:string -> keeper_id:string -> boot_observation

val write_publication :
  keepers_dir:string ->
  keeper_id:string -> publication_receipt -> (unit, string) result

val record_publication_journal :
  keepers_dir:string ->
  keeper_id:string ->
  publication_receipt -> (publication_receipt, string) result

val dispatch_publication :
  sync_parent:(Unix.file_descr -> 'a) ->
  keepers_dir:string ->
  keeper_id:string -> publication_receipt -> (unit, string) result

val recover_publication_with_sync :
  sync_parent:(Unix.file_descr -> 'a) ->
  keepers_dir:string -> keeper_id:string -> (unit, string) result

val recover_publication : keepers_dir:string -> keeper_id:string -> (unit, string) result
