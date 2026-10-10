(** Reference-based sweep for one keeper's stored media readings
    ({!Keeper_media_reading}), under [<masc_dir>/media-readings/<keeper>/].

    A stored reading is derived from an attachment that the canonical history
    keeps as inline base64. It stays useful while some durable record still
    carries that attachment. The sweep follows the two-pass candidate rule of
    {!Multimodal.Vision_kept_maintenance}:

    - one complete scan asks {!Multimodal.Vision_artifact_reference.is_referenced}
      whether each record's [source_probe] (a slice of the attachment's base64
      text) still occurs in a durable-consumer file; records that answer
      [Ok false] are this sweep's candidates;
    - the candidate set is persisted next to the records;
    - only a record that was a candidate in the previous complete sweep too is
      deleted.

    One rule differs from the vision store, because a reading can be derived
    again and a kept image cannot: a record that carries no [source_probe], or
    is not valid JSON, cannot be shown to be live and is a candidate like an
    unreferenced one. Deleting it costs one more reader call the next time the
    attachment is projected. Everything the sweep cannot read -- an unreadable
    record, a failed reference scan, a symlink -- still aborts the sweep before
    anything is deleted. *)

type error =
  | Invalid_store_root of
      { dir : string
      ; detail : string
      }
  | Record_read_failed of
      { name : string
      ; detail : string
      }
  | Reference_scan_failed of
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
  ; live : int (** records whose probe a durable file still contains *)
  ; unprobed : int (** records without a usable probe; also candidates *)
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

val run : masc_dir:string -> dir:string -> (report, error) result
(** Sweep one keeper directory. [masc_dir] is the root the reference scan
    reads durable consumers from. An absent [dir] is an empty report. *)
