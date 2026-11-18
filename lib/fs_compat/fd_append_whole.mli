(** Append a whole string through an [O_APPEND] descriptor, or leave the file
    as it was before the call.

    The plain append path writes each call's content with one {!run}. A write
    that stops part-way has already put some of the content at the end of the
    file. {!run} then truncates the file back to where the content started,
    so a failed append leaves nothing behind that a later append or a close
    could complete. The descriptor has no user-space buffer: bytes are either
    in the file when {!run} returns [Ok], or removed again.

    The caller serializes the writers of one file inside this process (the
    per-path append mutex). {!run} takes no file lock, so it relies on no
    other process appending to the same file during the call. *)

(** The descriptor operations {!run} performs. They are arguments so a test
    can make a write fail after a chosen number of bytes. *)
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
  }

val unix_io : io

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
  { write_failure : Fd_write_all.failure
  ; rollback : rollback
  }

(** [run ~io ~fd content] appends all of [content] or reports why it could
    not. On [Error], [rollback] says whether the file is back to its length
    before the call. Reading the position and truncating happen only after a
    failed write, so a successful append costs the write alone. *)
val run : io:io -> fd:Unix.file_descr -> string -> (unit, failure) result

val failure_to_string : failure -> string
