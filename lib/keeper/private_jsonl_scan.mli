(** Every complete row of a private JSONL store, from the first.

    The file is read a window of rows at a time, each under the store's
    lock ({!Fs_compat.read_private_jsonl_window_locked_result}). Rows
    appended while the scan runs are seen, and nothing is held between
    windows. Bytes after the last line break are not a row. *)

type error =
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Moved
  (** The offset the scan had reached no longer starts a row: the file was
      cut or replaced while it was being read. *)

val error_to_string : error -> string

(** [f] gets each row without its line break, with the byte offset it starts
    at. [rows_per_read] is how many rows one locked read takes. No file is
    no row. *)
val fold
  :  string
  -> rows_per_read:int
  -> init:'acc
  -> f:('acc -> at:int -> string -> 'acc)
  -> ('acc, error) result
