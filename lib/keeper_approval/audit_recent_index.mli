(** The approval audit store's newest rows per Keeper and for the whole store,
    decoded once and advanced over what changed since the previous read
    (RFC-0474 L4f). {!select} answers as the backward scan of the store would
    have: the same rows, or a refusal where that scan would have stopped. *)

val max_rows : int
(** Rows kept per Keeper and for the whole store. A read of more is refused by
    the caller rather than answered from a second path. *)

val malformed_row_detail :
  path:string -> line_number:int option -> detail:string -> string
(** How a row that is not JSON is named in a refusal. *)

type t
type refusal

val empty : t

type advance =
  | Advanced of t * refusal option
      (** [refusal] is the newest listing or file this read could not see;
          rows at or behind it are out of reach for this read only. *)
  | Rebuild_needed
      (** A day file shrank, no longer begins with the bytes its kept rows
          were decoded from, or was removed while an older one was left. The
          kept rows do not say which older rows they displaced, so the index
          starts over. Removing the oldest files, as retention does, only
          drops their rows. *)

val advance : Dated_jsonl.t -> t -> (advance, string) result
(** Read the day files written since [t] last read them. Unchanged files are
    only [lstat]ed; a changed file is read once from its first byte. *)

val rebuild : Dated_jsonl.t -> (t * refusal option, string) result
(** {!advance} from {!empty}. *)

val select :
  t ->
  refused:refusal option ->
  keeper_name:string option ->
  n:int ->
  (Yojson.Safe.t list, string) result
(** The [n] newest rows of [keeper_name], or of the whole store, newest first.
    [n] is at most {!max_rows}. *)
