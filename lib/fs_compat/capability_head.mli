(** Capability-relative, one-row durable HEAD authority.

    This surface deliberately does not expose append, scan, fallback, repair, or
    migration operations.  A HEAD is either absent, or exactly one non-empty
    LF-terminated row. *)

type cursor
type snapshot

val snapshot_row : snapshot -> string option
val snapshot_cursor : snapshot -> cursor
val snapshot_settlement_warnings : snapshot -> string list

type io_error =
  { operation : string
  ; detail : string
  }

type error =
  | Invalid_leaf of string
  | Invalid_row of string
  | Busy
  | Conflict of snapshot
  | Corrupt_lock of string
  | Corrupt_head of string
  | Unsupported of string
  | Io_error of io_error

type publication_indeterminate =
  { intended_sha256 : string
  ; intended_length : int64
  ; observed : cursor option
  }

type target_effect =
  | Unchanged
  | Publication_indeterminate of publication_indeterminate

type failure = private
  { error : error
  ; target_effect : target_effect
  ; settlement_warnings : string list
  }

type publication

val publication_cursor : publication -> cursor
val publication_settlement_warnings : publication -> string list

val read :
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  leaf:string ->
  (snapshot, failure) result

val compare_and_swap :
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  leaf:string ->
  expected:cursor ->
  row:string ->
  (publication, failure) result
