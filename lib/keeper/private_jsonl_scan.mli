(** Every complete row of a private JSONL store, from the first or from a
    given row.

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

(** What [f] says after a row: read on, or stop with a value. *)
type ('acc, 'stop) step =
  | Continue of 'acc
  | Stop of 'stop

type ('acc, 'stop) folded =
  | Reached_end of 'acc (** [f] had every row from the first one read. *)
  | Stopped of 'stop

type from_error =
  | Not_a_row_start of
      { from : int
      ; length : int (** The file's length. No file has length 0. *)
      }
  (** [from] is past the last row, or not just after a line break. *)
  | Scan_failed of error

(** As {!fold}, from the row that starts at [from] until [f] stops. A reader
    that saved where it stopped starts there: the rows before [from] are not
    read. No file is no row when [from] is 0. Raises [Invalid_argument] for
    a negative [from], as the window reader does. *)
val fold_from
  :  string
  -> from:int
  -> rows_per_read:int
  -> init:'acc
  -> f:('acc -> at:int -> string -> ('acc, 'stop) step)
  -> (('acc, 'stop) folded, from_error) result
