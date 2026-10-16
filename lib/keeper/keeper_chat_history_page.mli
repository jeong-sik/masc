(** Descriptor-bound, contiguous pages of the direct conversation file.
    Cursors name a physical file and an exact row boundary, independent of the
    row's wall clock. Atomic replacement, truncation, or a changed anchor refuses
    the cursor instead of advancing it through a different transcript. *)
type cursor

type error =
  | Invalid_cursor of string
  | Stale_cursor
  | Invalid_row of { offset : int; detail : string }
  | Row_exceeds_window
  | Io_error of string

val error_to_string : error -> string
val cursor_to_string : cursor -> string
val cursor_of_string : string -> (cursor, error) result

type source
(** An observed regular file identity, or absence. Identity includes device,
    inode, size, modification and change times; it is not an atomic snapshot. *)

val inspect_source : path:string -> (source, error) result
(** Open and inspect the named regular file without reading its contents.
    Only ENOENT is absence; unreadable and non-regular paths are errors. *)
val source_is_present : source -> bool
val source_fingerprint : source -> string

type row = { offset : int; line : string }
type page = { rows : row list; next_cursor : cursor option }

val read :
  path:string -> owner:string -> ?cursor:cursor -> max_rows:int -> unit ->
  (page, error) result
(** Read at most [max_rows] complete, consecutive nonblank rows before [cursor].
    [None] reads the newest page. Each raw file slice is bounded by the existing
    4 MiB transcript window (plus a separate bounded anchor read); a row crossing that whole window is reported,
    never skipped. An incomplete newest tail is an error and is retryable after
    its writer finishes. [next_cursor = None] means the file prefix is exhausted.
    The caller must validate every returned row before publishing the cursor. *)
