(** The diff reads bounded cold and live tails. It keeps requested events,
    sequence coordinates for detecting gaps, and their direct successor witnesses. *)
type range = Time of float * float | Revisions of int * int
val includes : range -> at:float -> revision:int option -> bool
val intersects : range -> Librarian_archive.folded -> bool
type cut = { by_rows : bool; by_bytes : bool }

(** Every source has observed the sequenced suffix from this point. A cut
    without any agreeing detail cannot put an upper bound on its lost prefix. *)
type sequence_suffix = From_sequence of int | Unknown_suffix

type t =
  { unsequenced : Librarian_archive.left list
  ; changes : Librarian_memory_change.t list
  ; folded : Librarian_archive.folded option
  ; unreadable : int
  ; conflicting : int
  ; unsequenced_count : int
  ; live_cut : cut
  ; archive_cut : cut
  ; details_limited : bool
  ; sequence_suffix : sequence_suffix
  ; input_limited : bool
  }
(** [archive_cut] describes limits relevant to the requested range.
    [details_limited] says that either source may have omitted sequenced rows.
    Omitting only unsequenced rows can limit input without hiding diagnostics
    derived from the sequenced rows. *)
val read : range:range -> max_bytes:int -> string -> (t, Private_jsonl_scan.error) result

val undecodable_rows : t -> int
(** The unreadable rows plus one for each conflicting sequence, saturated
    at the largest representable count. *)
