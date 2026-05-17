(** Date-split JSONL storage.

    Organises JSONL records into [base_dir/YYYY-MM/DD.jsonl] files.
    Stores rooted at the same [base_dir] share one {!Eio.Mutex.t} for
    concurrent-safe appends. *)

type t
(** Opaque handle.  Holds [base_dir] and the append mutex. *)

val create :
  base_dir:string -> ?mutex:Eio.Mutex.t -> ?retention_days:int -> unit -> t
(** [create ~base_dir ()] builds a store rooted at [base_dir].
    An optional [mutex] can be injected to bypass the shared registry
    (useful for testing).  When [?retention_days] is positive, [append]
    performs an opportunistic once-per-process-day prune of older day-files. *)

val base_dir : t -> string
(** Return the base directory of this store. *)

val append : t -> Yojson.Safe.t -> unit
(** Append [json] to today's [DD.jsonl] inside [YYYY-MM/].
    Creates directories as needed.  Thread-safe via internal mutex. *)

val set_append_guard : ((unit -> unit) -> unit) -> unit
(** [set_append_guard guard] installs a process-wide wrapper around
    {!append}.  The default guard runs the callback immediately.  Higher-level
    runtimes can install resource accounting/backpressure without making this
    low-level storage library depend on those policy modules. *)

val read_recent : t -> int -> Yojson.Safe.t list
(** [read_recent t n] returns the newest [n] entries in chronological order
    (oldest first).  Scans day-files from newest to oldest, stops early. *)

val read_recent_lines : t -> int -> string list
(** Like {!read_recent} but returns raw JSONL strings (no parse).
    Useful for tail-readers that do their own parsing. *)

val read_range : t -> since:string -> until:string -> Yojson.Safe.t list
(** [read_range t ~since ~until] returns entries whose day-file falls
    within [[since, until]] (inclusive, format ["YYYY-MM-DD"]).
    Result is in chronological order. *)

val iter_all : t -> (Yojson.Safe.t -> unit) -> unit
(** [iter_all t f] calls [f] for every parseable JSONL entry in chronological
    order without loading a whole day-file into memory. Malformed rows are
    skipped, matching {!read_recent} and {!read_range}. *)

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
(* [count_entries t] returns the total number of non-empty lines across all
   day-files. Scans files by counting newlines without JSON parsing. *)

val load_tail_lines : string -> max_lines:int -> string list
(** [load_tail_lines file ~max_lines] efficiently reads the last [max_lines]
    from a large file without loading the whole file into memory.
    Reads backwards in chunks. Returns chronologically (oldest first). *)

module For_testing : sig
  val mutex : t -> Eio.Mutex.t
  (** Expose the internal mutex so tests can verify sharing. *)

  val mutex_for_base_dir : string -> Eio.Mutex.t
  (** Lookup or insert the registry entry for [base_dir].
      Equivalent to the default-mutex path of {!create}. *)

  val registry_size : unit -> int
  (** Number of distinct [base_dir] keys currently held by the
      file-scope mutex registry. *)

  val reset_append_guard : unit -> unit
end
