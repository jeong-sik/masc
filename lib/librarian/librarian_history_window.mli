(** The diff reads bounded cold and live tails. It keeps requested events,
    sequence coordinates for detecting gaps, and their direct successor witnesses. *)
type range = Time of float * float | Revisions of int * int
val includes : range -> at:float -> revision:int option -> bool
val intersects : range -> Librarian_archive.folded -> bool
type cut = { by_rows : bool; by_bytes : bool }

type t =
  { unsequenced : Librarian_archive.left list
  ; changes : Librarian_memory_change.t list
  ; folded : Librarian_archive.folded option
  ; unreadable : int
  ; conflicting : int
  ; unsequenced_count : int
  ; live_cut : cut
  ; archive_cut : cut
  ; input_limited : bool
  }
val read : range:range -> max_bytes:int -> string -> (t, Private_jsonl_scan.error) result
