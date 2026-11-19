(** A Keeper's turn log on disk
    (RFC librarian-call-only-proposes §5.2): read the tail, append at the end
    that was read.

    Every append reads the tail first and names the end offset it read. An
    append whose end offset is no longer the end writes nothing, and the
    caller reads the tail again. So two writers cannot both append after the
    same line, and a writer never decides from a tail that has moved.

    Nothing is kept in memory between calls. *)

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** The [Opened] line that no [Closed] follows. *)
type open_turn =
  { opened : int (** Byte offset of the [Opened] line. A [Closed] names it. *)
  ; baseline : Keeper_turn_log.mark
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

(** Reads back from the end only as far as it must: to the last line that
    ends a unit and to the last [Opened] or [Closed]. In a file the writing
    rules produced that is a few lines. *)
val read_tail : string -> (tail, read_error) result

type append_error =
  | End_moved of
      { expected : int
      ; actual : int
      }
  (** Another append landed first. Nothing was written. Read the tail again. *)
  | Directory_unavailable of
      { path : string
      ; detail : string
      }
  | Write_failed of
      { path : string
      ; detail : string
      }

(** Appends one or more lines in one write: all of them land or none does.
    [at_end] is [rows_end] of the tail the caller read, or [0] for
    [Nothing_written]. Returns the new end. *)
val append
  :  path:string
  -> at_end:int
  -> Keeper_turn_log.line * Keeper_turn_log.line list
  -> (int, append_error) result
