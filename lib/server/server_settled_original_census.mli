(** Startup count of the settled originals no live record names (RFC-0498
    layer one). It reads and counts; it moves and deletes nothing.

    A live record names the request IDs its progress events hold and, for a
    gate record, its parent execution. The callers that ask whether an
    original is settled pass only those IDs. An archived record whose ID no
    live record names is one the later pass would delete. Every archived body
    is counted: no code reads an archived body. *)

type report =
  { live_records : int
  ; named_ids : int  (** Distinct request IDs the live records name. *)
  ; archived_records : int
  ; archived_record_bytes : int64
  ; unnamed_records : int  (** Archived records no live record names. *)
  ; unnamed_record_bytes : int64
  ; archived_bodies : int
  ; archived_body_bytes : int64
  }

type error = Census_unavailable of string

val error_to_string : error -> string

val run : store:Lane_addon_store.t -> (report, error) result
(** Call while the workspace process lease excludes original writers and
    settles. A live record in a scope no owner claims, one that does not
    decode, a gate whose parent cannot be read, or an archive entry of an
    unknown shape refuses the count. The error names the class of failure,
    never record or body content. Byte counts are logical file sizes. *)

val run_at_startup : base_path:string -> (report, error) result
(** As {!run} for the workspace runtime store. A missing runtime root counts
    nothing. *)
