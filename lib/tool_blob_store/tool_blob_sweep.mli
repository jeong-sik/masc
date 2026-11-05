(** The in-server sweep of the shared {!Tool_blob_store} (RFC-0499), layer
    one: it counts and records, and deletes nothing.

    A scan writes a marker file and takes the marker's mtime as the scan's
    start, so later comparisons with blob mtimes read one filesystem clock.
    It then scans the durable consumers through
    {!Tool_blob_maintenance.live_references}, lists the blobs and writes the
    candidate record [<base>/.masc/tool_blob_maintenance/candidates-v2].

    Against the previous record it computes what layer two would delete: the
    blobs that were candidates then and are candidates now, that this process
    has not marked in {!Tool_blob_store}'s touch ledger, and whose file has not
    been written since the previous scan opened. It also classifies the
    previous record's deletable blobs that a durable consumer references now:
    layer two would have deleted them, so each one shows whether a [put]
    would have written the file again, a [fetch] would have failed visibly,
    or a reference would have been left without its file.

    The touch ledger rotates only after a record is written. A failed scan
    rotates nothing, so the two generations together always reach back past
    the previous recorded scan's opening. *)

type previous_now_live =
  { rewritten : int
      (** A [put] mark, or a file written after the previous scan opened. *)
  ; read_only : int  (** Only a read mark. *)
  ; untouched : int
      (** No mark and an older file: a reference layer two would have left
          without its file. Their digests are the [u] lines of the record. *)
  }

type previous_comparison =
  { previous_deletable : int
  ; previous_deletable_read : int
      (** Previous deletable blobs with a read mark, referenced now or not. *)
  ; now_live : previous_now_live
  }

type report =
  { scan_started_at : float
  ; scan_seconds : float
  ; live_digests : int
  ; blobs : int
  ; candidates : int
  ; deletable : int
  ; deletable_bytes : int
  ; unstatable : int
      (** Candidates of both scans whose file was neither a regular file nor
          absent; never deletable. *)
  ; previous : previous_comparison option  (** [None] on the first scan. *)
  ; touches : Tool_blob_store.touch_counts
  }

type error =
  | Scan_failed of Tool_blob_maintenance.error
  | Listing_failed of Tool_blob_store.list_error
  | Record_unreadable of
      { path : string
      ; detail : string
      }
  | Record_invalid of
      { path : string
      ; line : int
      ; detail : string
      }
  | Record_write_failed of
      { path : string
      ; detail : string
      }
  | Marker_failed of
      { path : string
      ; detail : string
      }

val error_to_string : error -> string
val report_to_string : report -> string

val record_path : base_path:string -> string
val marker_path : base_path:string -> string

type schedule =
  | Due
  | Next_at of float

val schedule : base_path:string -> now:float -> (schedule, error) result
(** [Due] when no scan has opened, or a day has passed since the last one
    opened. A scan that opened and failed counts: the next attempt waits a day
    from its opening. *)

val observe :
  base_path:string ->
  board_posts_file:(workspace_masc_dir:string -> string) ->
  (report, error) result
(** One scan. Blocking, with no Eio effects: run it off the main domain. *)
