(** Date-split JSONL storage.

    Organises JSONL records into [base_dir/YYYY-MM/DD.jsonl] files.
    Stores rooted at the same [base_dir] share one {!Eio.Mutex.t} for
    concurrent-safe appends. *)

type t
(** Opaque handle.  Holds [base_dir] and the append mutex. *)

type read_operation =
  | Inspect
  | List_directory
  | Open_file
  | Read_file

type layout_entry_kind =
  | Month_directory
  | Day_file

type non_regular_file_kind =
  | Directory
  | Symbolic_link
  | Character_device
  | Block_device
  | Fifo
  | Socket

type read_error =
  | Invalid_offset of { offset : int }
  | Invalid_date_range of
      { since : string
      ; until : string
      }
  | Not_a_directory of { path : string }
  | Invalid_layout_entry of
      { parent : string
      ; entry : string
      ; expected : layout_entry_kind
      }
  | Non_regular_file of
      { path : string
      ; kind : non_regular_file_kind
      }
  | Io_error of
      { operation : read_operation
      ; path : string
      ; detail : string
      }

type recent_entry =
  | Parsed of Yojson.Safe.t
  | Malformed_json of
      { path : string
      ; line_number : int option
      ; detail : string
      }

val read_error_to_string : read_error -> string
(** Render a typed storage read failure for operator-facing diagnostics. *)

val create :
  base_dir:string ->
  ?mutex:Eio.Mutex.t ->
  ?retention_days:int ->
  ?max_bytes:int ->
  unit ->
  t
(** [create ~base_dir ()] builds a store rooted at [base_dir].
    An optional [mutex] can be injected to bypass the shared registry
    (useful for testing).  When [?retention_days] is positive, [append]
    performs an opportunistic once-per-process-day prune of older day-files.
    When [?max_bytes] is positive, [append] prunes oldest completed day-files
    until the store is at or below the cap, while preserving the current
    day-file. *)

val base_dir : t -> string
(** Return the base directory of this store. *)

val prepare_for_directory_removal : t -> unit
(** Close the current append writer and forget its memoized month directory
    and row count before application-owned code removes [base_dir t]. A later
    append can then recreate the directory and observe the new file identity. *)

val append : t -> Yojson.Safe.t -> unit
(** Append [json] to today's [DD.jsonl] inside [YYYY-MM/].
    Creates directories as needed.  Thread-safe via internal mutex. *)

type append_outcome =
  | Appended_to_current
      (** The row landed in today's current [DD.jsonl]. *)
  | Appended_after_rotation of { segment : string }
      (** Today's file reached the cap and was renamed to the completed
          segment [DD.NNN.jsonl] named here; the row landed in a fresh
          current file. *)
  | Skipped_rotation_exhausted of { sequence_limit : int }
      (** The day already holds [sequence_limit] rotated segments — the
          [NNN] name space is spent — so the row was dropped. *)
  | Skipped_by_append_guard
      (** The installed {!set_append_guard} declined to run the append. *)

val append_rotating :
  t -> max_current_file_bytes:int -> Yojson.Safe.t -> append_outcome
(** Append [json] to today's current [DD.jsonl], rotating the file to a
    completed [DD.NNN.jsonl] segment first when the row would push it
    over [max_current_file_bytes] (a non-positive cap never rotates).
    Rotated segments are ordinary completed files: readers include them
    in day order, and the [?max_bytes] byte-budget prune from {!create}
    removes the oldest of them first while the current file survives —
    so a capped store keeps the newest records and sheds the oldest,
    instead of dropping new rows for the rest of the day.

    A single row larger than the cap lands in an empty current file
    anyway (the segment runs oversized once) — rotating an empty file
    out would spin without ever accepting the row. The size check,
    rename, and append share the same internal mutex as {!append};
    retention and byte-budget pruning still run after a successful
    append. *)

val set_append_guard : ((unit -> unit) -> unit) -> unit
(** [set_append_guard guard] installs a process-wide wrapper around
    {!append}.  The default guard runs the callback immediately.  Higher-level
    runtimes can install resource accounting/backpressure without making this
    low-level storage library depend on those policy modules. *)

val collect_matching :
  ?offset:int -> t -> int -> f:(Yojson.Safe.t -> 'a option) -> 'a list
(** [collect_matching ?offset t n ~f] returns the newest [n] values [f]
    produced. Where {!filter_map_recent} counts rows read, this counts values
    selected, so [n] means what a filtering caller intended by it.

    Use it whenever [f] rejects rows. With {!filter_map_recent} such a caller
    has no value of [n] that means "the newest [n] matches": the budget fills
    with whatever was written last, and unrelated writes can consume all of it.
    Multiplying [n] to compensate only moves the write rate at which the answer
    goes empty.

    Day files are walked newest-first and scanned backwards in fixed-size
    chunks. The scan stops at the [n]-th match and never materialises a whole
    day file; memory is bounded by the current chunk/line fragment plus the
    selected values.

    [offset] skips selected values, not rows. Ordering and malformed-row
    skipping match {!filter_map_recent}, including that {b [f] is called
    newest-first}. *)

val collect_matching_range :
  ?offset:int ->
  t ->
  since:string ->
  until:string ->
  int ->
  f:(Yojson.Safe.t -> 'a option) ->
  'a list
(** Range-bounded {!collect_matching}. Only day files in the inclusive
    [[since, until]] UTC date range are opened. Invalid or reversed dates
    return [[]], matching {!filter_map_range_recent}; row-level [f] remains
    responsible for exact timestamp boundaries within the edge days. *)

val filter_map_recent :
  ?offset:int -> t -> int -> f:(Yojson.Safe.t -> 'a option) -> 'a list
(** [filter_map_recent ?offset t n ~f] is [List.filter_map f (read_recent
    ?offset t n)] without ever holding the intermediate [Yojson.Safe.t list].
    [f] is applied to each parsed row as it is read, so a row's tree is
    unreachable before the next row is parsed; the result list is the only
    thing that accumulates.

    [n] and [offset] count parsed rows, not selected ones: [f] returning [None]
    does not make the reader consume an extra row. The returned list, the
    offset semantics, and malformed-row skipping match {!read_recent} exactly.

    {b [f] is called newest-first.} The scan walks months, day-files, and rows
    in descending order and prepends, which is what makes the {e result}
    chronological. So for a pure [f] this is exactly [List.filter_map f
    (read_recent ?offset t n)], but for an [f] whose side effects depend on
    call order — rate-limited error logging, "report the first N drops",
    anything that stops after a quota — it is not: those effects see the
    newest rows first. Convert such a call site with a test that pins the
    effect, not by substitution.

    Callers that decode rows into their own record type should prefer this over
    [read_recent |> List.filter_map]: a [`Assoc] holds one cons cell, one tuple,
    and one boxed value per field, so the tree is roughly 25x the source bytes
    and a 100k-row window materialises gigabytes that the decoder immediately
    discards. *)

val read_recent : ?offset:int -> t -> int -> Yojson.Safe.t list
(** [read_recent ?offset t n] returns the newest [n] entries in chronological
    order (oldest first), skipping the first [offset] newest entries.
    Scans day-files from newest to oldest, stops early.

    Holds every row's parsed tree at once. Use {!filter_map_recent} when the
    rows are being decoded into something smaller. *)

val read_recent_result :
  ?offset:int -> t -> int -> (recent_entry list, read_error) result
(** Strict bounded recent-row read. The limit and offset count physical,
    non-empty JSONL rows, including {!Malformed_json} rows. Missing stores are
    [Ok []]. The reader accepts only [YYYY-MM/DD.jsonl] layout entries and
    regular day files; symbolic links, other file kinds, and I/O failures are
    returned explicitly. Results are chronological (oldest first). *)

val find_latest_entry_result :
  t -> (recent_entry -> 'a option) -> ('a option, read_error) result
(** Scan physical rows from newest to oldest and return the first value
    selected by the callback. The scan reads each visited byte at most once,
    keeps only one reverse-I/O chunk in memory, and stops immediately after a
    match. Malformed rows are delivered to the callback. Missing stores return
    [Ok None]; layout and I/O failures remain explicit. *)

val read_recent_lines : ?offset:int -> t -> int -> string list
(** Like {!read_recent} but returns raw JSONL strings (no parse).
    Useful for tail-readers that do their own parsing. *)

val read_range : t -> since:string -> until:string -> Yojson.Safe.t list
(** [read_range t ~since ~until] returns entries whose day-file falls
    within [[since, until]] (inclusive, format ["YYYY-MM-DD"]).
    Result is in chronological order. *)

val filter_map_range_recent
  :  ?offset:int
  -> t
  -> since:string
  -> until:string
  -> int
  -> f:(Yojson.Safe.t -> 'a option)
  -> 'a list
(** Range counterpart to {!filter_map_recent}: [List.filter_map f
    (read_range_recent ?offset t ~since ~until n)] without ever holding the
    intermediate [Yojson.Safe.t list].

    Same contract as {!filter_map_recent} in every respect that matters —
    [n] and [offset] count parsed rows rather than selected ones, the returned
    list is chronological, and {b [f] is called newest-first}, so a projection
    whose side effects depend on call order is not interchangeable with the
    [read_range_recent |> List.filter_map] form. *)

val read_range_recent
  :  ?offset:int
  -> t
  -> since:string
  -> until:string
  -> int
  -> Yojson.Safe.t list
(** [read_range_recent ?offset t ~since ~until n] returns at most the newest
    [n] entries whose day-file falls within [[since, until]] (inclusive). Reads
    newest day-file first and only the tail of each file, so it parses ~[n]
    entries instead of the whole window — use it instead of {!read_range} when
    a result bound exists and the window may span large stores. Result is
    chronological (oldest-first) within the collected set, matching
    {!read_recent}. *)

val iter_all : t -> (Yojson.Safe.t -> unit) -> unit
(** [iter_all t f] calls [f] for every parseable JSONL entry in chronological
    order without loading a whole day-file into memory. Malformed rows are
    skipped, matching {!read_recent} and {!read_range}. *)

val iter_all_entries_result :
  t -> (recent_entry -> unit) -> (unit, read_error) result
(** Stream every physical, non-empty JSONL row in chronological order. JSON
    syntax failures are delivered as {!Malformed_json} entries and do not stop
    iteration. The same closed layout and regular-file boundary as
    {!read_recent_result} applies; storage failures are returned explicitly.
    Missing stores are empty. *)

val iter_range_entries_result :
  t ->
  since:string ->
  until:string ->
  (recent_entry -> unit) ->
  (unit, read_error) result
(** Strict chronological iteration over day files in the inclusive
    [[since, until]] range. JSON syntax failures are delivered as
    {!Malformed_json}; invalid ranges and selected-path storage failures are
    returned explicitly. Entries that are not valid dated paths are outside
    the requested range and do not gate the read. Files outside the requested
    day range are not opened. *)

val iter_range : t -> since:string -> until:string -> (Yojson.Safe.t -> unit) -> unit
(** Streaming variant of {!read_range}. Invalid dates iterate zero rows. *)

val prune : t -> days:int -> int
(** [prune t ~days] deletes day-files older than [days] days ago.
    Returns the number of files deleted.  Removes empty month directories. *)

(* OCaml 5.3 emits warning 32 on this exported signature item under
   [warn-error=+a] even though the implementation and internal call sites are
   present. Keep the suppression scoped to this declaration only. *)
[@@@warning "-32"]
val count_entries : t -> int
[@@@warning "+32"]
(* [count_entries t] returns the total number of non-empty,
   newline-terminated lines across all day-files. Scans bytes without
   JSON parsing, backed by a per-file (boundary, count) cache: closed
   day-files are never re-read and the growing current-day file only
   re-reads the bytes appended since the previous call, so a call is
   O(appended bytes) — exact, no TTL staleness window (the RFC-0162
   §3.2 TTL layer this replaced traded 10 s of staleness for a bound
   the incremental cache now provides structurally). A trailing line
   not yet terminated by '\n' is not counted until its newline lands;
   audit callers that must include it use [count_entries_uncached]. *)

val count_entries_uncached : t -> int
(** Like [count_entries] but bypasses the per-file cache and counts a
    trailing unterminated line. Use in tests or rare audit paths that
    must observe the live filesystem byte-for-byte. *)

val save_count_cache : path:string -> (unit, string) result
(** Writes the per-file (path, boundary, count) cache to [path] via a
    temp-file rename. The cache is never an authority: every entry is still
    validated against the file's current size when it is used, so a stale or
    absent file only costs the full count it costs today. An empty cache
    writes nothing. *)

val load_count_cache : path:string -> (int, string) result
(** Loads a cache written by {!save_count_cache}, returning how many rows were
    read. Rows merge into the in-memory table and never overwrite an entry
    this process has already advanced further. A missing file is [Ok 0]:
    counting from scratch is correct, just slower. *)

val reset_count_cache_for_testing : unit -> unit
(** Reset the per-file incremental count cache. Test-only. *)

val load_tail_lines : string -> max_lines:int -> string list
(** [load_tail_lines file ~max_lines] efficiently reads the last [max_lines]
    from a large file without loading the whole file into memory.
    The read, the scan and the split run on the process domain pool when
    one is installed, so the calling fiber's scheduler is not held for them.
    Reads backwards in chunks. Returns chronologically (oldest first). A
    missing file is an empty tail; other open and read errors are exceptions. *)

module For_testing : sig
  val mutex : t -> Eio.Mutex.t
  (** Expose the internal mutex so tests can verify sharing. *)

  val mutex_for_base_dir : string -> Eio.Mutex.t
  (** Lookup or insert the registry entry for [base_dir].
      Equivalent to the default-mutex path of {!create}. *)

end
