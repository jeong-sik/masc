(** Date-split JSONL storage.

    Organises JSONL records into [base_dir/YYYY-MM/DD.jsonl] files.
    Stores rooted at the same [base_dir] share one {!Cross_context_mutex.t} for
    concurrent-safe appends from fibers and OS threads.

    Day-file readers coordinate descriptor admission and final close with the
    canonical data-path mutex used by cooperative private-file writers. Row
    callbacks run outside that mutex, and chunked scans retain one channel.
    This does not add an atomic content snapshot or arbitrary inode-alias
    coordination; each reader retains its existing captured extent/tail policy. *)

type t
(** Opaque handle. Holds the store's location. *)

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

module Store = Dated_jsonl_store
(** The closed list of stores and where each one lives. *)
module Layout = Dated_jsonl_layout
(** Shared calendar and numeric rotation ordering for read continuations. *)

val open_store :
  ?max_bytes:int ->
  Store.location ->
  t
(** Open the store at a listed location. A store can be opened only where
    {!Store} puts it.

    The writers of one store directory take one mutex, whichever spelling
    reached the directory. The process registry keeps it under the name the
    file system gives the directory ([File_system_named.name]). A handle asks
    for it on each write or prune, so a handle opened before its directory
    existed takes the directory's mutex once the directory is there. The
    file system is asked once for each spelling of a directory that exists;
    a spelling keeps that answer until {!directories_removed} is called. A
    caller that only reads and must leave no entry behind opens a {!Reader}.

    When [?max_bytes] is positive, [append] prunes
    oldest completed day-files until the store is at or below the cap, while
    preserving the current day-file. Day files are removed by age only by
    {!prune_listed_stores_bound}. *)

val base_dir : t -> string
(** Return the base directory of this store. *)

val close : t -> unit
(** Close the current append writer handle for [t] without invalidating
    directory or row-count caches. Use when releasing a store handle whose
    directory remains on disk. *)

val prepare_for_directory_removal : t -> unit
(** Close the current append writer and forget every cached day-file row count
    under [base_dir t] before application-owned code removes [base_dir t]. A
    later append makes the directory again whether or not this was called; what
    it adds is the descriptor closed before the removal and cached row counts
    cleared across all retained days. The removal is followed by
    {!directories_removed}. *)

val directories_removed : unit -> unit
(** Tell this module that store directories, or files inside them, were
    removed or renamed by code outside it. Called after the removal, on every
    way out of it: a removal that failed half-way has changed files too.

    Every fact kept in memory ({!read_fact}) is forgotten, for every store,
    and so is every directory name the file system gave; the next read of a
    fact reads the files and the next write asks the file system again. Which
    directories were removed is not looked at. A removal that is not followed
    by this call leaves the facts of the removed store as they were. *)

val append : t -> Yojson.Safe.t -> unit
(** Append [json] to today's [DD.jsonl] inside [YYYY-MM/].
    Creates directories as needed. Thread-safe via the store's
    {!Cross_context_mutex}, which serializes Eio fibers and raw OS threads
    alike: a [Thread.create] worker appends the audit log through this path,
    and an [Eio.Mutex] there would suspend it through an effect it has no
    handler for, killing the thread before the row lands. *)

exception Append_guard_skipped
(** The append guard returned without allowing a commit-aware append. *)

val append_notifying_commit : t -> Yojson.Safe.t -> on_committed:(unit -> unit) -> unit
(** Same as {!append}, and calls [on_committed] once the row is in the file,
    before retention and byte-budget pruning run. An exception raised after
    [on_committed] returned leaves the row durable; one raised before it
    leaves nothing written. A caller that retries a failed append uses this to
    tell the two apart, so it does not write the same row twice.
    Raises [Append_guard_skipped] when the guard declines the callback. *)

type append_outcome =
  | Appended_to_current
      (** The row landed in today's current [DD.jsonl]. *)
  | Appended_after_rotation of { segment : string }
      (** Today's file reached the cap and was renamed to the completed
          segment [DD.SEQUENCE.jsonl] named here; the row landed in a fresh
          current file. *)
  | Skipped_rotation_exhausted of { sequence_limit : int }
      (** The highest segment sequence has reached [sequence_limit] ([max_int]);
          another integer identity cannot be represented. No file is replaced. *)
  | Skipped_by_append_guard
      (** The installed {!set_append_guard} declined to run the append. *)

val append_rotating :
  ?on_committed:(unit -> unit) ->
  t -> max_current_file_bytes:int -> Yojson.Safe.t -> append_outcome
(** Append [json] to today's current [DD.jsonl], rotating the file to a
    completed [DD.SEQUENCE.jsonl] segment first when the row would push it
    over [max_current_file_bytes] (a non-positive cap never rotates).
    Rotated segments are ordinary completed files: readers include them
    in day and numeric sequence order (sequences have at least three digits,
    and grow past 999), and the [?max_bytes] byte-budget prune from {!open_store}
    removes the oldest of them first while the current file survives —
    so a capped store keeps the newest records and sheds the oldest,
    instead of dropping new rows for the rest of the day.

    A single row larger than the cap lands in an empty current file
    anyway (the segment runs oversized once) — rotating an empty file
    out would spin without ever accepting the row. The size check,
    rename, and append share the same internal mutex as {!append};
    retention and byte-budget pruning still run after a successful
    append. [on_committed] runs after the row is written, before pruning,
    including when the append rotated the file. It never runs for a skipped
    append. A failure after the callback leaves the row committed, as with
    {!append_notifying_commit}. *)

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
    selected values. A day file removed by concurrent retention after the
    directory snapshot is skipped; other open failures still reach the
    caller.

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

type 'a recent_view
(** A {!filter_map_recent} read with a fixed row count and projection that
    keeps each store's answer until the store's day files change. The kept
    answers live in the view, so make one view per projection and keep it.
    The view holds one answer per store directory it has read, for as long
    as the view lives; an answer for a store that is gone is never served,
    because its files no longer match. *)

val recent_view : int -> f:(Yojson.Safe.t -> 'a option) -> 'a recent_view
(** [recent_view n ~f] reads like [filter_map_recent t n ~f]. [f] must be
    pure: a kept answer is returned without calling it again. *)

val read_recent_view : 'a recent_view -> t -> 'a list
(** [read_recent_view view t] is [filter_map_recent t n ~f] for the view's
    [n] and [f]. It lists [t]'s day files once and reads from that list.
    When the list equals the one the previous read used, and every file that
    read opened is still the same file (device and inode) with the same size
    and modification time, it returns that read's answer without opening a
    day file.

    A listing that fails, or a file whose identity cannot be taken before it
    is read, keeps no answer; the call still returns what
    [filter_map_recent] returns. A file replaced in place by different bytes
    with the same inode, size and modification time reads as unchanged; the
    store's writers only append and remove whole files. *)

val count_and_read_recent_view : 'a recent_view -> t -> int * 'a list
(** Count all retained complete lines and project the recent window from one
    shared day-file listing. Reuses the existing per-file count cache and
    recent-view invalidation; files are still checked for external changes.
    Counts use [count_entries]'s [.jsonl] selection, including dot-prefixed
    files. Recent rows keep the view's validated dated-file selection.
    This is a best-effort observation, not an atomic multi-file snapshot.
    On listing failure, uses the same permissive count/recent readers without
    retaining a recent answer under an incomplete listing. *)

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
    returned explicitly. In the store's own directory it passes over the
    entries the store declares as side files ({!Store.is_side_file}).
    Results are chronological (oldest first). *)

val find_latest_entry_result :
  t -> (recent_entry -> 'a option) -> ('a option, read_error) result
(** Scan physical rows from newest to oldest and return the first value
    selected by the callback. The scan reads each visited byte at most once,
    keeps only one reverse-I/O chunk in memory, and stops immediately after a
    match. Malformed rows are delivered to the callback. Missing stores return
    [Ok None]; layout and I/O failures remain explicit. *)

(** {1 Facts kept in memory}

    A fact is one value read from a store's files that this module also keeps
    in memory, so that a reader does not open a file for it (RFC "Keeper row
    facts are kept in memory by their writers"). The files stay the
    authority: while nothing is changing them, the kept value is the value
    the fact's strict read gives.

    The functions of this module that change a store's files keep the facts
    right themselves: {!append}, {!append_notifying_commit} and
    {!append_rotating} move a kept value over the row they wrote, and
    {!prune}, {!prune_listed_stores_bound}, an append's own byte-budget prune
    and any append that fails forget the store's facts. A change made any
    other way is told with {!directories_removed}.

    That holds for the appends of one process. A row another process appends
    moves nothing here, so a fact is kept only where two things hold: the
    process has said it holds the workspace's writer lease
    ({!Fact_cell.keep_in_this_process}), and the store is one whose files
    only the lease holder changes ({!Store.facts}). Anywhere else
    {!read_fact} reads the files each time: in the TUI or a command line
    tool for every store, and in the lease holder for a store such as the
    cost log, which [masc-cost] also appends to without a lease. *)

type 'a fact

val last_row : recent_entry option fact
(** The store's newest physical row, as [read_recent_result t 1] reads it:
    [None] for a store without rows, and a row that is not JSON is
    {!Malformed_json}. *)

val last_rows : name:string -> count:int -> Yojson.Safe.t option list fact
(** A fact: the store's newest [count] physical rows, oldest first, as
    [read_recent_result t count] reads them. A row is its JSON; a row that is
    not JSON is [None] and keeps its place among the [count]. The value names
    no file, so a size rotation leaves it as it is.

    Each call makes a fact of its own, with its own kept value in every
    store. Make it once, where the count is defined, and keep it. [name]
    labels its reads in [masc_dated_jsonl_fact_reads_total].

    @raise Invalid_argument when [count] is less than 1. *)

val last_lines : name:string -> count:int -> string list fact
(** A fact: the lines of the store's newest [count] physical rows, oldest
    first, as [read_recent_lines_result t count] reads them: each row's text
    without its newline, whether or not it is JSON. As {!last_rows}, with the
    rows left as text for a reader that decodes the few it needs: 120 rows of
    2.8 kB took four times the memory as parsed JSON that they take as text.

    @raise Invalid_argument when [count] is less than 1. *)

val parse_line : string -> (Yojson.Safe.t, string) result
(** One row's text as the strict reads decode it: its JSON, or what the
    parser said of a row that is not JSON ({!Malformed_json}). For a reader
    of {!last_lines}. *)

val newest_parsed_row : Yojson.Safe.t option fact
(** The store's newest row that is JSON, as {!find_latest_entry_result} finds
    it when it selects every {!Parsed} row: rows that are not JSON are passed
    over, and [None] is a store in which no row is JSON. *)

val newest_selected
  :  name:string
  -> select:(base_dir:string -> recent_entry -> 'a option)
  -> 'a option fact
(** A fact: what [select] gives for the store's newest row it selects, as
    [find_latest_entry_result t (select ~base_dir:(base_dir t))] finds it,
    and [None] for a store in which it selects no row.

    [select] is told the store's directory, for a selection that reports the
    rows it cannot use. It runs on each row the search visits when the files
    are read, and once on each row appended while the value is kept. What it
    answers for a row must depend on the row alone: an appended row it passes
    over leaves the kept value as it is.

    Each call makes a fact of its own, with its own kept value in every
    store. Make it once, where the selection is defined, and keep it. [name]
    labels its reads in [masc_dated_jsonl_fact_reads_total]. *)

val read_fact : t -> 'a fact -> ('a, read_error) Fact_cell.filled
(** The fact's value for the store. When the store keeps it, no file is read
    and no system call is made for a directory that exists
    ({!Fact_cell.Held}). Otherwise the fact's strict read runs, in one pool job
    for a caller outside the pool, and the store keeps the value unless its
    files changed meanwhile. A failed read keeps nothing.

    A store whose directory does not exist yet is asked about each time, as
    for a write.

    In a process that has not said {!Fact_cell.keep_in_this_process} the strict
    read runs on every call and nothing is kept: the answer is
    {!Fact_cell.Read_not_kept} or {!Fact_cell.Read_failed}.

    Each call is counted in
    [Otel_builtin_metric_names.metric_dated_jsonl_fact_reads] by the kind of
    store, the fact and the constructor of the answer. *)

val month_dir_paths_newest_first_result : t -> (string list, read_error) result
(** The store's month directories, newest first, listed and validated as
    {!find_latest_entry_result} lists them. A missing store is empty. *)

val day_file_paths_newest_first_result : string -> (string list, read_error) result
(** The day files of one month directory from
    {!month_dir_paths_newest_first_result}, newest first, listed and validated
    as {!find_latest_entry_result} lists them. *)

val compare_day_file_names : string -> string -> int
(** The order of two day file names within one month, oldest first: the order
    {!day_file_paths_newest_first_result} lists them in, reversed. *)

val entry_of_physical_line : path:string -> string -> recent_entry option
(** One physical line of a day file of [path], without its newline, as
    {!find_latest_entry_result} reads it: [None] when it holds only whitespace,
    which no reader counts as a row, and the decoded row otherwise. *)

val find_latest_entry_in_file_result :
  string -> (recent_entry -> 'a option) -> ('a option, read_error) result
(** Single-file reverse scan using the same chunked reader as
    {!find_latest_entry_result}. Calls the callback newest-first until it
    selects a value or the file ends. Malformed rows reach the callback;
    missing or non-regular files and I/O failures are errors. *)

val read_recent_lines : ?offset:int -> t -> int -> string list
(** Like {!read_recent} but returns raw JSONL strings (no parse).
    Useful for tail-readers that do their own parsing. *)

val read_recent_lines_result :
  ?offset:int -> t -> int -> ((string * string) list, read_error) result
(** Strict raw counterpart of {!read_recent_result}, with the same physical
    non-empty row selection, chronological order, offset and storage errors.
    Each pair carries the source path and the original line without its newline.
    JSON is not parsed: a caller can compare exact already-validated source
    bytes before decoding them again. Malformed JSON still occupies a row. *)

val range_day_file_paths_result :
  t -> since:string -> until:string -> (string list, read_error) result
(** Enumerate the complete selected dated paths, oldest first. A missing
    store is empty; invalid ranges and failures to inspect or list the store
    or a selected month are errors. Foreign names are ignored, as with
    {!iter_range_entries_result}. Day files are not opened. *)

val range_day_file_paths : t -> since:string -> until:string -> string list
(** The day files the inclusive [[since, until]] range covers, oldest first,
    without opening any of them. Same day-selection rule as {!iter_range}, so a
    path returned here is a file that call would have read. Invalid dates give
    the empty list. *)

val fold_range_appended_raw
  :  t
  -> since:string
  -> until:string
  -> cursors:(string * int) list
  -> init:'acc
  -> f:('acc -> string -> 'acc)
  -> 'acc * (string * int) list
(** Fold only the raw lines a range gained since [cursors] said each file was
    read to, and return the accumulator with the cursors advanced.
    Unlike {!fold_range_appended}, lines are passed unparsed so callers can
    pre-filter or decode selectively. *)

val fold_range_appended
  :  t
  -> since:string
  -> until:string
  -> cursors:(string * int) list
  -> init:'acc
  -> f:('acc -> Yojson.Safe.t -> 'acc)
  -> 'acc * (string * int) list
(** Fold only the rows a range gained since [cursors] said each file was read
    to, and return the accumulator with the cursors advanced.

    A day file is append-only, so a caller holding a trailing-window answer can
    keep its accumulator and pass the cursors back rather than reading the
    window again. A path absent from [cursors] is read whole; malformed rows
    are skipped as {!iter_range} skips them.

    A file that shrank below its cursor (rotation, rewrite) is re-read from
    zero, so such a caller double-counts rather than under-counts. Compare the
    returned cursor against the one passed to detect it. *)

type append_cursor
(** File identities, observed sizes and complete-line boundaries from one
    successful strict incremental read. Owned by this module. *)

type 'a appended_read =
  | Appended of 'a * append_cursor
  | Cursor_invalidated

val fold_range_appended_result :
  t -> since:string -> until:string -> cursor:append_cursor option ->
  init:'a -> f:('a -> Yojson.Safe.t -> 'a) ->
  ('a appended_read, read_error) result
(** Strict incremental read using the same complete range as
    {!range_day_file_paths_result}. Missing previous files, replacement,
    shrinkage or a same-size metadata change invalidate the cursor before
    invoking [f]. The caller must discard its accumulator and read with
    [cursor:None]. New files and appended bytes are read without replaying
    retained files. In-place prefix edits combined with growth are outside
    the append-only file contract.

    Reads use verified regular-file handles and stop at captured sizes;
    incomplete trailing lines are retried on the next call. A file or layout
    change observed during the read is an error, as are inspection/open/read
    failures. [f] may already have run before an error or exception, so a
    mutable accumulator must be discarded in either case. Only [Appended]
    authorizes retaining the returned cursor. Malformed JSON rows are skipped
    as in {!fold_range_appended}; callback exceptions propagate unchanged. *)

val fold_file_appended_entries_result :
  string -> cursor:append_cursor option -> init:'a ->
  f:('a -> recent_entry -> 'a) -> ('a appended_read, read_error) result
(** Strict single-file counterpart to {!fold_range_appended_result}. It reports
    malformed complete lines to [f] instead of skipping them. An incomplete final
    row is an error. A removed file is
    an error; rotation, shrinkage and same-size edits invalidate the cursor.
    Appended bytes are read only once. The same append-only contract applies:
    in-place prefix edits combined with growth are outside that contract. *)

val fold_file_appended_complete_entries_result :
  string -> cursor:append_cursor option -> init:'a ->
  f:('a -> recent_entry -> 'a) -> ('a appended_read, read_error) result
(** {!fold_file_appended_entries_result} for a reader that may run while a
    line is being written. It stops at the last complete line and keeps its
    cursor there, so an incomplete final row is read on a later call once it
    is complete, or once the writer cuts it and appends another. *)

val fold_private_file_appended_entries_result :
  string -> cursor:append_cursor option -> init:'a ->
  f:('a -> recent_entry -> 'a) ->
  (('a * recent_entry option) appended_read, read_error) result
(** As {!fold_file_appended_complete_entries_result}, for a file whose writer
    takes the private JSONL path and descriptor locks before appending. The
    captured extent excludes writes still subject to rollback. Also returns
    the unterminated row, if nonblank, outside the accumulator and cursor. *)

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

val prune_listed_stores_bound :
  Store.root -> Fs_compat.Retention_directory.t -> operator_window_days:int ->
  on_pruned:(Store.location -> unit) -> int
(** Prune every store in {!Store.all} by its {!Store.retention}, through
    descriptor-owned traversal of the declared geometry and the caller's
    already bound runtime root, so a shared flat/dated pass never reopens its
    root by pathname. [operator_window_days] is the workspace's window for
    [Operator_window] stores. [on_pruned] is called once for each store
    directory the pass deleted a day file from, after its lock is released.
    Returns the number of day files deleted. *)

(* OCaml 5.3 emits warning 32 on this exported signature item under
   [warn-error=+a] even though the implementation and internal call sites are
   present. Keep the suppression scoped to this declaration only. *)
[@@@warning "-32"]
val count_entries : t -> int
[@@@warning "+32"]
(* [count_entries t] returns the total number of non-empty,
   newline-terminated lines across all day-files. Scans bytes without
   JSON parsing, backed by a per-file (dev, ino, boundary, count) cache:
   closed files with matching identity and unchanged size avoid content reads;
   growing files with matching identity read only appended bytes; replaced
   files (different device or inode) or shrunk files rescan from byte 0. Every
   call still lists retained files and stats each one, with no TTL staleness
   window. A trailing line not yet terminated by '\n' is not counted until its
   newline lands; audit callers that must include it use
   [count_entries_uncached]. *)

val count_entries_uncached : t -> int
(** Like [count_entries] but bypasses the per-file cache and counts a
    trailing unterminated line. Use in tests or rare audit paths that
    must observe the live filesystem byte-for-byte. *)

val count_cache_filename : string
(** The count cache's file name below [<base>/.masc]. *)

val save_count_cache : path:string -> (unit, string) result
(** Writes the per-file (path, dev, ino, boundary, count) cache to [path] via a
    temp-file rename. The cache is never an authority: every entry is validated
    against the file's current device, inode, and size when used, so a stale
    or absent file only costs a full count. An empty cache writes nothing. *)

val load_count_cache : path:string -> (int, string) result
(** Loads a cache written by {!save_count_cache}, returning how many rows were
    read. Legacy rows without [dev]/[ino] are ignored so stale pre-upgrade
    entries cannot match replaced files. Rows merge into the in-memory table
    and never overwrite an entry this process has measured for another file
    identity or advanced further. A missing file is [Ok 0]: counting from
    scratch is correct, just slower. *)

val reset_count_cache_for_testing : unit -> unit
(** Reset the per-file incremental count cache. Test-only. *)

val load_tail_lines : string -> max_lines:int -> string list
(** [load_tail_lines file ~max_lines] efficiently reads the last [max_lines]
    from a large file without loading the whole file into memory.
    The read, the scan and the split run on the process domain pool when
    one is installed, so the calling fiber's scheduler is not held for them.
    Reads backwards in chunks. Returns chronologically (oldest first). A
    missing file is an empty tail; other open and read errors are exceptions. *)

(** One non-blank line of a tail and the byte offset in the file where it
    starts. In a file that is only appended to, the offset names the line for
    as long as the file exists, whatever the window it was read in. *)
type tail_row =
  { offset : int
  ; line : string
  }

val load_tail_rows : string -> max_lines:int -> tail_row list
(** {!load_tail_lines} with each line's starting offset. Same read, same
    order, same errors. *)

val map_tail_rows : string -> max_lines:int -> f:(tail_row -> 'a) -> 'a list
(** {!load_tail_rows} with [f] applied to each row in the same pool job as the
    read, so a caller that parses the rows does not come back to its own
    domain between the read and the parse. [f] must not touch state owned by
    the calling fiber. *)

val map_tail_rows_result :
  string -> max_lines:int -> f:(tail_row -> 'a) -> ('a list, read_error) result
(** {!map_tail_rows} with open and read failures as values. A missing file is
    [Ok []]. A path that cannot be opened, is not a regular file once opened,
    or cannot be read is [Error]. *)

(** A handle that reads one store and is not in the store registry.

    A reader never asks for the store's mutex, so a route that reads the
    store of whatever Keeper name a client sent does not grow the registry
    by one entry per made-up name. No function that writes or prunes takes
    a reader: every change of a store's files goes through a handle that
    takes the store's mutex. *)
module Reader : sig
  type t

  val open_store : Store.location -> t
  val base_dir : t -> string

  val read_recent_result :
    ?offset:int -> t -> int -> (recent_entry list, read_error) result
  (** {!val:Dated_jsonl.read_recent_result} of the reader's store. *)

  val read_recent_lines_result :
    ?offset:int -> t -> int -> ((string * string) list, read_error) result
  (** {!val:Dated_jsonl.read_recent_lines_result} of the reader's store. *)
end

module For_testing : sig
  val cross_context_mutex : t -> Cross_context_mutex.t
  (** The mutex a write through the handle would take now. *)

  val in_registry : Store.location -> bool
  (** Whether the registry holds an entry for the store. *)

  val after_row :
    ?base_dir:string ->
    ?line:string ->
    'a fact ->
    value:'a ->
    newest:(string * string) option ->
    row:recent_entry ->
    written:string * string ->
    ('a * (string * string) option) option
  (** What an append makes of a kept value. [value] saw its newest row in the
      day file [newest], and [row] went to the end of the day file [written];
      a day file is its month directory and its file name. The result is the
      value after the row with the newest day file it saw, or [None] when the
      append forgets the fact instead. It reads no file and no clock.
      [base_dir] is the store's directory as a {!newest_selected} selection
      is told it; the current directory's name when left out. [line] is the
      row's text, which only {!last_lines} looks at; the empty text when left
      out. *)
end
