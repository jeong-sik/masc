(** A Keeper's turn log on disk
    (RFC librarian-call-only-proposes §5.2): read the tail, append at the end
    that was read.

    Every append reads the tail first and names the end offset it read. An
    append whose end offset is no longer the end writes nothing, and the
    caller reads the tail again. So two writers cannot both append after the
    same line, and a writer never decides from a tail that has moved.

    Nothing is kept in memory between calls.

    The tail is taken in two locked reads: where the rows end, then the rows
    before that end. Another append may land between them or after them. The
    tail is then older than the file, and the append at its end is refused
    as {!End_moved}. *)

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** The [Opened] line that no [Closed] follows. *)
type open_turn =
  { opened : int (** Byte offset of the [Opened] line. A [Closed] names it. *)
  ; baseline : Keeper_turn_log.mark
  ; reset_since : bool
  (** A [Reset] follows the [Opened]. What was closed since is then not this
      turn's to claim. *)
  }

type tail =
  | Nothing_written
  (** No file, or no complete line. A fragment an append left behind is not a
      line. An append at offset 0 cuts it. *)
  | Written of
      { rows_end : int (** Just past the last complete line. Append here. *)
      ; point : Keeper_turn_log.mark (** Where the next unit starts. *)
      ; open_turn : open_turn option
      ; last : Keeper_turn_log.line
      }

type undecodable =
  | Not_json
  | Malformed of Keeper_memory_os_types.wire_error

type read_error =
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Row_undecodable of
      { offset : int
      ; reason : undecodable
      }
  (** A line the tail needs does not decode. The writer does not guess what it
      was: it appends nothing until the line is dealt with. *)
  | Log_start_missing (** There are lines and none of them starts the log. *)
  | Moved_while_reading
  (** The second read did not find the rows the first one ended at: the file
      was cut or replaced in between, or the rows were not handed over one by
      one from the end. No offset from this read is to be trusted. *)

(** Reads back from the end only as far as it must: to the last line that
    ends a unit and to the last [Opened] or [Closed]. In a file the writing
    rules produced that is a few lines. *)
val read_tail : string -> (tail, read_error) result

(** The line that starts the log. It is the first line, at offset 0. *)
type start =
  { id : Keeper_turn_log.Log_id.t
  ; at : float
  ; mark : Keeper_turn_log.mark
  }

(** Reads the first line only. [None] when there is no file or no complete
    line. A first line that is not a [Log_started] is {!Log_start_missing}. *)
val read_start : string -> (start option, read_error) result

type scanned =
  { at : int (** Byte offset of the line. *)
  ; past : int (** Just past the line's line break: where the next line starts. *)
  ; line : (Keeper_turn_log.line, undecodable) result
  (** A line that does not decode is given as such and does not end the
      scan. *)
  }

(** How many lines one locked read takes. An append waits for one such read
    at most. *)
val scan_window_rows : int

(** Every complete line from the first, in order ({!Private_jsonl_scan}).
    No file is no line. *)
val fold
  :  string
  -> init:'acc
  -> f:('acc -> scanned -> 'acc)
  -> ('acc, Private_jsonl_scan.error) result

(** The lines from the one that starts at [from], in order, until [f] stops
    ({!Private_jsonl_scan.fold_from}). The lines before [from] are not read:
    a reader that saved where it stopped reads on from there. *)
val fold_from
  :  string
  -> from:int
  -> init:'acc
  -> f:('acc -> scanned -> ('acc, 'stop) Private_jsonl_scan.step)
  -> (('acc, 'stop) Private_jsonl_scan.folded, Private_jsonl_scan.from_error) result

(** Only {!End_moved} is worth reading the tail again for at once. After the
    other two the caller writes no line for this event; whoever writes next
    reads the tail afresh. *)
type append_error =
  | End_moved of
      { expected : int
      ; actual : int
      }
  (** The rows no longer end where the caller read them to end. Nothing was
      written. [actual] is the length of the file. It equals [expected] when
      the file was replaced by one of that length that ends in a fragment. *)
  | Directory_unavailable of
      { path : string
      ; detail : string
      }
  | Write_failed of
      { path : string
      ; detail : string
      }

type appended =
  { new_end : int
  ; last_at : int
  (** Byte offset of the last line appended. An admission's [Opened] is the
      last line of its append, and the turn's [Closed] names this offset. *)
  }

(** Appends one or more lines in one write: all of them land or none does.
    [at_end] is [rows_end] of the tail the caller read, or [0] for
    [Nothing_written]. *)
val append
  :  path:string
  -> at_end:int
  -> Keeper_turn_log.line * Keeper_turn_log.line list
  -> (appended, append_error) result
