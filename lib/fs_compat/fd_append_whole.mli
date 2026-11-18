(** Append a whole string through an [O_APPEND] descriptor, or leave the file
    as it was before the call.

    The plain append path writes each call's content with one {!run}. A write
    that stops part-way has already put some of the content at the end of the
    file. {!run} then truncates the file back to where the content started,
    so a failed append leaves nothing behind that a later append or a close
    could complete. The descriptor has no user-space buffer: bytes are either
    in the file when {!run} returns [Ok], or removed again.

    A caller that writes lines asks for {!At_line_start}. {!run} then reads
    the file's last byte before it writes. When the file ends in the middle
    of a line, the append writes a newline first, so its lines never join
    onto bytes an earlier writer left unfinished. The newline belongs to the
    same all-or-nothing write as the content.

    The last byte is read from the file on every such call and nothing about
    the file's end is remembered between calls. A remembered end would be
    wrong after another descriptor changed the file, and no cheaper check
    than the read tells whether one did.

    The caller serializes the writers of one file inside this process (the
    per-path append mutex). {!run} takes no file lock, so it relies on no
    other process appending to the same file during the call. *)

(** The end of a file, read through the descriptor. *)
type observed_end =
  | Empty
  | Last_byte of char

(** The descriptor operations {!run} performs. They are arguments so a test
    can make one of them fail. *)
type io =
  { write : Unix.file_descr -> string -> int -> int -> int
    (** [write fd content offset length], as
        [Unix.single_write_substring]: one attempt that returns how many
        bytes it wrote, and has written none when it raises. {!run}
        counts the bytes to remove from these results, so a [write]
        that raises after writing some bytes breaks the rollback. *)
  ; position : Unix.file_descr -> int
    (** The descriptor's offset. Right after a write through an [O_APPEND]
        descriptor it is the end of the bytes that write added. *)
  ; truncate : Unix.file_descr -> int -> unit
    (** [truncate fd length], as [Unix.ftruncate]. *)
  ; observe_end : Unix.file_descr -> observed_end
    (** Reads the file's last byte. The descriptor must be open for
        reading. It may move the descriptor's offset: an [O_APPEND]
        write lands at the end of the file wherever the offset is. *)
  }

val unix_io : io

(** Where an append begins. *)
type start =
  | Anywhere
    (** Right after the file's last byte, whatever that byte is. *)
  | At_line_start
    (** On a new line. When the file is not empty and its last byte is not
        a newline, a newline is written before the content. *)

(** What became of the bytes a failed append had already written. *)
type rollback =
  | Nothing_written
  | Rolled_back of { bytes : int }
  | Rollback_failed of
      { bytes : int (** still at the end of the file *)
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }

type failure =
  | End_unreadable of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }
    (** An {!At_line_start} append could not read the file's last byte.
        Nothing was written. *)
  | Write_failed of
      { write_failure : Fd_write_all.failure
      ; rollback : rollback
      }
    (** [rollback] says whether the file is back to its length before the
        call. *)

(** [run ~io ~start ~fd content] appends all of [content] or reports why it
    could not. An empty [content] writes nothing, not even the newline of
    {!At_line_start}.

    A successful {!Anywhere} append costs the write alone. An
    {!At_line_start} append also reads the last byte first. The position and
    the truncation happen only after a failed write. *)
val run
  :  io:io
  -> start:start
  -> fd:Unix.file_descr
  -> string
  -> (unit, failure) result

val failure_to_string : failure -> string
