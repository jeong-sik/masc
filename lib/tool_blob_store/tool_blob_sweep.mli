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

type attachment_sweep_report =
  { total_blobs : int
  ; live_blobs : int
  ; unreferenced_blobs : int
  ; deleted : int
  ; retained_within_grace : int
  ; delete_failures : int
  ; blocked_by_unclassified : bool
  }

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
  ; attachment_sweep : (attachment_sweep_report, string) result option
      (** Outcome of {!sweep_attachments} during {!reclaim} when [unclassified]
          is empty; [None] on {!observe} or when blocked by unclassified entries. *)
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

(** {1 Attachment reachability} *)

type attachment_reachability =
  { live_sha256s : Set_util.StringSet.t
  ; total_blobs : int
  ; unreferenced_sha256s : Set_util.StringSet.t
  ; scanned_files : int
  }

val scan_attachment_reachability :
  base_path:string ->
  scope:Tool_blob_maintenance.scope ->
  (attachment_reachability, string) result
(** Read-only fail-closed reachability scan for {!Attachment_store}: walks every
    in-scope durable store named by [scope] (including [keeper_chat/*.jsonl],
    [board_posts.jsonl], [board_comments.jsonl], [keepers/], etc.), config
    keeper files, and active ephemeral pins under
    [<base>/.masc/attachments/ephemeral/] for canonical [att_<64hex>]
    references and for the bare [/api/v1/media/<64hex>] and
    [![[media:<64hex>]]] forms the wiki lint accepts
    ({!Media_ref_scan.extract_bare_media_digests}), then computes live and
    unreferenced digests against
    [<base>/.masc/attachments/blobs/]. Fails closed with [Error _] on any
    unreadable directory, consumer file, ephemeral pin dir, or blob shard.
    Deletes nothing. *)

val sweep_attachments :
  ?min_age_seconds:float ->
  ?now:float ->
  base_path:string ->
  scope:Tool_blob_maintenance.scope ->
  unit ->
  (attachment_sweep_report, string) result
(** Reclaim verified unreferenced {!Attachment_store} blobs older than
    [min_age_seconds] (default 24 hours). Also invoked from {!reclaim} when no
    unclassified entries exist.
    Fail-closed guarantees:
    - Aborts with [Error _] (deleting nothing) if any consumer file/directory,
      [ephemeral/] directory, or [blobs/] shard cannot be read.
    - Refuses to delete ([blocked_by_unclassified = true], [deleted = 0]) when
      {!Tool_blob_maintenance.unclassified_entries} is non-empty.
    - Retains blobs whose latest blob/sidecar mtime is within [min_age_seconds]
      of [now] and re-verifies ephemeral pins immediately before unlinking. *)
