(** Memory history events.

    This module records retrieval as typed events in a per-keeper append-only
    sidecar, [<keeper>.memory-events.jsonl], and projects them at read time
    together with the revisions and retractions the memory journal records. It
    stores no strength, score, or threshold; every number a consumer shows is
    computed from what it reads.

    Only reads live here. A retrieval changes no snapshot, so it has no commit
    log row to ride on, and it is written on the turn path by
    [keeper_memory_search] and [keeper_memory_select]. Revisions and
    retractions change the snapshot, and the commit's own {!Librarian_log} row
    is their record: a separate append after the commit could be lost to a
    cancellation or crash in between (#37433). Events outlive the fact they
    name; a dropped fact keeps its events and a reader attaches them only to
    facts that still exist. *)

(** What happened to the memory. A closed set: a new kind of event is a new
    constructor, and the compiler names every consumer that has to learn it. *)
type event_kind =
  | Retrieved of { query : string }
  (** The fact was among the results [keeper_memory_search] or
      [keeper_memory_select] returned for [query]. Assessment without delivery
      does not create a retrieval event. *)

type event =
  { recorded_at : float (** Unix seconds, the producer's clock. *)
  ; memory_id : string (** The fact this happened to. *)
  ; trace_id : string (** The turn it happened in; empty when there is none. *)
  ; kind : event_kind
  }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val suffix : string

(** {1 Codec}

    One JSON object per line. [recorded_at], [memory_id], [trace_id], [kind]
    and the kind's payload ([query]). The decoder rejects a missing, extra or
    duplicate field, an unknown kind token (including the [retracted] and
    [revised] rows earlier builds wrote), a non-finite time, a string that is
    not a memory id, and a blank [query]. *)

val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, Keeper_memory_os_types.wire_error) result

(** {1 Sidecar} *)

type append_error =
  | Invalid_event of Keeper_memory_os_types.wire_error
  (** The event fails the same checks the decoder applies; nothing was
      written. *)
  | Write_failed of
      { path : string
      ; message : string
      }

val append_error_to_string : append_error -> string

(** Validate, then append one line. The append holds the sidecar's path lock
    and fsyncs. A final row that a crash cut short, with no newline, is cut off
    first so the new line starts on its own. The caller decides what a failure
    means on its path: a search that could not record its [Retrieved] still
    returns its results, and says so in its log. *)
val append : keepers_dir:string -> keeper_id:string -> event -> (unit, append_error) result

(** Append the events in order. The valid ones go in one locked append, and
    only that new suffix is rolled back when the write fails: a torn tail cut
    off first stays cut, since restoring it would re-corrupt the file. Only
    the failures come back, the rejected events first and then the write
    failure if there was one; a caller on a path that must not fail logs them
    and goes on. *)
val append_all : keepers_dir:string -> keeper_id:string -> event list -> append_error list

type read_error =
  | Not_json of string
  | Malformed of Keeper_memory_os_types.wire_error

type file_read_error =
  { path : string
  ; message : string
  }

val read_error_to_string : read_error -> string
val file_read_error_to_string : file_read_error -> string

(** Every non-blank line of the sidecar in file order, paired with its
    zero-based index among non-blank lines. A line this module cannot read
    stays in the list as an [Error] so a reader can count and name it instead
    of losing it. A missing file reads as no events. A sidecar lookup or read
    failure is returned separately, so callers cannot confuse it with an empty
    history. *)
val read :
  keepers_dir:string ->
  keeper_id:string ->
  ((int * (event, read_error) result) list, file_read_error) result

(** {1 Projection} *)

type summary =
  { retrieved_count : int
  ; retrieved_distinct_days : int
  (** Distinct UTC calendar days on which the fact was retrieved. Spacing is
      shown as a count of days, not turned into a score. *)
  ; last_retrieved_at : float option
  ; retracted_count : int
  (** Explicit retractions of this memory id in the journal lineage. *)
  ; revised_from : string list
  (** Memory ids of facts whose journal revision link names this fact as their
      successor, sorted, without repeats. *)
  }

val summaries_for :
  memory_ids:string list ->
  revisions:Keeper_memory_os_types.revision list ->
  retractions:string list ->
  event list -> summary list
(** Analyze one captured event list and commit-log lineage
    ({!Librarian_log_store}) for only the requested ids. Results have exactly
    the requested order and length, including duplicate ids. A requested id
    with no events and no lineage has an empty summary. Incoming revisions from
    unrequested predecessors still count; self-revisions do not. No state
    crosses calls. *)

(** The summary on the wire: the five fields by name, [last_retrieved_at]
    null when the fact was never retrieved. *)
val summary_to_json : summary -> Yojson.Safe.t
