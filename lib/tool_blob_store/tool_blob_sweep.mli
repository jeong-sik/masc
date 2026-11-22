(** The in-server sweep of the shared {!Tool_blob_store}: {!observe} counts and
    records without deleting; {!reclaim} additionally deletes confirmed
    two-generation unreferenced blobs once every safety gate holds.

    A scan writes a marker file and takes the marker's mtime as the scan's
    start, so later comparisons with blob mtimes read one filesystem clock.
    It then scans the durable consumers through
    {!Tool_blob_maintenance.live_references}, lists the entries the scope
    leaves unclassified ({!Tool_blob_maintenance.unclassified_entries}),
    lists the blobs and writes the candidate record
    [<base>/.masc/tool_blob_maintenance/candidates-v2]. The record header
    names the unclassified entries. A record that names one has no deletable
    blob: the scan does not read that entry.

    Against the previous record it computes what a deleting sweep would
    delete: the blobs that were candidates then and are candidates now, that
    this process has not marked in {!Tool_blob_store}'s touch ledger, and
    whose file has not been written since the previous scan opened. It also
    classifies the previous record's deletable blobs that a durable consumer
    references now: a deleting sweep would have deleted them, so each one
    shows whether a [put] would have written the file again, a [fetch] would
    have failed visibly, or a reference would have been left without its
    file.

    The touch ledger rotates only after a record is written. A failed scan
    rotates nothing, so the two generations together always reach back past
    the previous recorded scan's opening. *)

type previous_now_live =
  { rewritten : int
      (** A [put] mark, or a file written after the previous scan opened. *)
  ; read_only : int  (** Only a read mark. *)
  ; untouched : int
      (** No mark and an older file: a reference that a deleting sweep would
          have left without its file. Their digests are the [u] lines of the
          record. *)
  }

type previous_comparison =
  { previous_deletable : int
  ; previous_deletable_read : int
      (** Previous deletable blobs with a read mark, referenced now or not. *)
  ; now_live : previous_now_live
  }

type previous =
  | No_previous_record  (** The first scan of this workspace. *)
  | Previous_record_invalid of
      { line : int
      ; detail : string
      }
      (** The record does not parse. This scan compares nothing and writes a
          new record in its place, so nothing becomes deletable before the
          next scan. *)
  | Compared_with_previous of previous_comparison

type report =
  { scan_started_at : float
  ; scan_seconds : float
  ; live_digests : int
  ; blobs : int
  ; candidates : int
  ; deletable : int
  ; deletable_bytes : int
  ; deleted : int
  ; deleted_bytes : int
  ; delete_failures : int
  ; unstatable : int
      (** Candidates of both scans whose file was neither a regular file nor
          absent; never deletable. *)
  ; unclassified : string list
      (** {!Tool_blob_maintenance.unclassified_entry_to_string} of each
          unclassified entry. Non-empty, [deletable] is 0. *)
  ; malformed_warnings : Tool_blob_maintenance.malformed_reference_warning list
      (** Malformed legacy structured [_blob] references encountered during
          scanning. Any {!Tool_blob_maintenance.Unpinnable_malformed_blob_ref}
          keeps [deletable] at 0 and prevents deletion fail-closed. *)
  ; previous : previous
  ; touches : Tool_blob_store.touch_counts
  }

type error =
  | Scan_failed of Tool_blob_maintenance.error
  | Listing_failed of Tool_blob_store.list_error
  | Record_unreadable of
      { path : string
      ; detail : string
      }
  | Record_write_failed of
      { path : string
      ; detail : string
      ; deleted : int
      ; deleted_bytes : int
      ; delete_failures : int
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
  scope:Tool_blob_maintenance.scope ->
  (report, error) result
(** One observation-only scan. Deletes nothing. Blocking, with no Eio effects:
    run it off the main domain. *)

val reclaim :
  ?min_age_seconds:float ->
  base_path:string ->
  scope:Tool_blob_maintenance.scope ->
  unit ->
  (report, error) result
(** One scan with safe, gated deletion of confirmed two-generation unreferenced
    blobs. Deletes a blob only when:
    - a valid previous [candidates-v2] record exists,
    - [unclassified] is empty,
    - no {!Tool_blob_maintenance.Unpinnable_malformed_blob_ref} was encountered,
    - the touch ledger has not evicted marks in either generation
      ([not current_evicted && not previous_evicted], re-checked immediately
      before unlinking),
    - the blob is absent from the touch ledger in both generations (re-checked
      immediately before unlinking), and
    - the blob's mtime is strictly older than the previous scan opening and at
      least [min_age_seconds] (default 24h) older than this scan's opening
      (re-checked immediately before unlinking).
    Blocking, with no Eio effects: run it off the main domain. *)
