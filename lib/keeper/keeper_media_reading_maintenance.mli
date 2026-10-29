(** Reference-based sweep for one keeper's stored media readings
    ({!Keeper_media_reading}), under [<masc_dir>/media-readings/<keeper>/].

    A stored reading is derived from an attachment that the canonical history
    keeps as a [Stored] reference, and its record name carries that
    reference's sha256. It stays useful while some durable record still holds
    the reference. The sweep follows the two-pass candidate rule of
    {!Multimodal.Vision_kept_maintenance}:

    - one complete scan of {!Tool_blob_maintenance}'s durable-consumer
      registry ({!Tool_blob_maintenance.live_references}) gives the [Stored]
      digests that are live; a record whose digest is not among them is this
      sweep's candidate;
    - the candidate set is persisted next to the records;
    - only a record that was a candidate in the previous complete sweep too is
      deleted.

    Everything the sweep cannot read -- an unreadable store root or record
    entry, a symlinked record, an undecodable candidate snapshot -- aborts the
    sweep before anything is deleted. *)

type error =
  | Invalid_store_root of
      { dir : string
      ; detail : string
      }
  | Record_read_failed of
      { name : string
      ; detail : string
      }
  | Snapshot_read_failed of { detail : string }
  | Snapshot_write_failed of { detail : string }
  | Delete_failed of
      { name : string
      ; detail : string
      }

val error_to_string : error -> string

type report =
  { scanned : int (** records observed in the keeper directory *)
  ; live : int (** records whose attachment a durable consumer still holds *)
  ; candidates_recorded : int (** candidates recorded for the next sweep *)
  ; deleted : int (** records deleted: candidates in the previous sweep too *)
  ; reclaimed_bytes : Int64.t
  ; remaining_count : int
  ; remaining_bytes : Int64.t
  }

val is_record_name : string -> bool
(** [<audio|document>-<64 lowercase hex>-<media type>.json], the names
    {!Keeper_media_reading} writes. Other entries are left alone. *)

val keeper_dirs : masc_dir:string -> (string list, error) result
(** The per-keeper directories under [<masc_dir>/media-readings], sorted. An
    absent store is an empty list. *)

val run : live:Tool_blob_maintenance.live_references -> dir:string -> (report, error) result
(** Sweep one keeper directory against [live], one scan shared by every
    keeper directory of a pass. An absent [dir] is an empty report. *)
