(** Pure framing-independent decoding of one persisted posts row.
    Blank rows retain their line number at the caller. No diagnostics are
    emitted here, including when a rejected outer row carries nested errors. *)
type row =
  | Blank
  | Accepted of {
      post : Board_types.post;
      diagnostics : Board_content_json.diagnostic list;
    }
  | Rejected of {
      error : Board_types.posts_row_error;
      diagnostics : Board_content_json.diagnostic list;
    }

(** Weak ephemeron cache keyed by physical identity ([==]) of immutable
    [private_jsonl_snapshot.bytes] strings. Old snapshots become GC-eligible
    as soon as the source observation advances. *)
module Snapshot_bytes_cache : sig
  type 'a t

  val create : int -> 'a t
  val find_opt : 'a t -> string -> 'a option
  val replace : 'a t -> string -> 'a -> unit
end

(** Canonical byte slice inside a snapshot [bytes] string (including its
    trailing ['\n']). *)
type slice = {
  offset : int;
  length : int;
}

val slice_has_content : string -> start:int -> stop:int -> bool
(** True when [bytes[start..stop)] contains at least one non-ASCII-whitespace
    byte, without allocating a trimmed copy. Raises [Invalid_argument] when
    [start < 0] or [stop > String.length bytes]. *)

val is_canonical_slice : string -> start:int -> stop:int -> has_newline:bool -> bool
(** True when [bytes[start..stop)] is a clean JSON object line without leading
    or trailing whitespace and followed by ['\n']. *)

val iter_lines_with_offsets :
  string -> (line_number:int -> start:int -> stop:int -> has_newline:bool -> unit) -> unit
(** Streaming line scan over [bytes] without allocating a split-line list. *)

val decode : line:int -> string -> row

val register_snapshot :
  bytes:string ->
  by_id:Board_types.post Set_util.StringMap.t ->
  slices:slice Set_util.StringMap.t ->
  covered_bytes:int ->
  unit

val register_append :
  before_bytes:string ->
  after_bytes:string ->
  offset:int ->
  length:int ->
  Board_types.post ->
  unit

val all_in_snapshot :
  Fs_compat.private_jsonl_snapshot ->
  (Board_types.post Set_util.StringMap.t, Board_types.board_error) result
(** Pure physical-order decode of every post in [snapshot]. Every row must
    decode, and the last row for each ID wins. Uses the weak snapshot cache on
    hit. *)

val latest : post_id:string -> Fs_compat.private_jsonl_snapshot ->
  (Board_types.post, Board_types.board_error) result
(** Pure physical-order lookup. Every row must decode, and the last matching
    row wins as on reload. No parser diagnostics or other effects are emitted. *)

val render_snapshot :
  ?replacement:Board_types.post ->
  base_bytes:string ->
  (string, Board_types.post) Hashtbl.t ->
  string
(** Render [table] (with optional [replacement]) into JSONL bytes, reusing
    exact byte slices from [base_bytes] for physically unchanged posts instead
    of retaining a second full copy in [store.post_rows]. *)
