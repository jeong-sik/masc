(** Date-split JSONL storage.

    Organises JSONL records into [base_dir/YYYY-MM/DD.jsonl] files.
    Each instance carries its own {!Eio.Mutex.t} for concurrent-safe appends. *)

(** Opaque handle.  Holds [base_dir] and a per-store mutex. *)
type t

(** [create ~base_dir ()] builds a store rooted at [base_dir].
    An optional [mutex] can be injected (useful for testing). *)
val create : base_dir:string -> ?mutex:Eio.Mutex.t -> unit -> t

(** Return the base directory of this store. *)
val base_dir : t -> string

(** Append [json] to today's [DD.jsonl] inside [YYYY-MM/].
    Creates directories as needed.  Thread-safe via internal mutex. *)
val append : t -> Yojson.Safe.t -> unit

(** [read_recent t n] returns the newest [n] entries in chronological order
    (oldest first).  Scans day-files from newest to oldest, stops early. *)
val read_recent : t -> int -> Yojson.Safe.t list

(** Like {!read_recent} but returns raw JSONL strings (no parse).
    Useful for tail-readers that do their own parsing. *)
val read_recent_lines : t -> int -> string list

(** [read_range t ~since ~until] returns entries whose day-file falls
    within [[since, until]] (inclusive, format ["YYYY-MM-DD"]).
    Result is in chronological order. *)
val read_range : t -> since:string -> until:string -> Yojson.Safe.t list

(** [prune t ~days] deletes day-files older than [days] days ago.
    Returns the number of files deleted.  Removes empty month directories. *)
val prune : t -> days:int -> int

(* OCaml 5.3 emits warning 32 on this exported signature item under
   [warn-error=+a] even though the implementation and internal call sites are
   present. Keep the suppression scoped to this declaration only. *)
[@@@warning "-32"]

val count_entries : t -> int

[@@@warning "+32"]
(* [count_entries t] returns the total number of non-empty lines across all
   day-files. Scans files by counting newlines without JSON parsing. *)

(** [load_tail_lines file ~max_lines] efficiently reads the last [max_lines]
    from a large file without loading the whole file into memory.
    Reads backwards in chunks. Returns chronologically (oldest first). *)
val load_tail_lines : string -> max_lines:int -> string list

module For_testing : sig
  (** Expose the internal mutex so tests can verify sharing. *)
  val mutex : t -> Eio.Mutex.t

  (** Lookup or insert the registry entry for [base_dir].
      Equivalent to the default-mutex path of {!create}. *)
  val mutex_for_base_dir : string -> Eio.Mutex.t

  (** Number of distinct [base_dir] keys currently held by the
      file-scope mutex registry. *)
  val registry_size : unit -> int
end
