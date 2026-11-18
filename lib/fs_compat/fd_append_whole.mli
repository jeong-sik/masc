(** Append a whole string through an [O_APPEND] descriptor.

    The plain append path writes each call's content with one {!run}. The
    descriptor has no user-space buffer, so when {!run} returns, no byte of
    the content is left to reach the file later.

    {2 A failed write}

    A write that stops part-way has already put some of the content at the
    end of the file. {!run} then takes those bytes out again, but only when
    it can tell they are the file's last bytes and nobody else's: the file
    must be exactly as long as it was before the call plus the bytes this
    call wrote. Otherwise {!run} removes nothing and the result says so
    ({!Not_rolled_back}). A file that became shorter is not grown back.

    The check is on the file's length, not on its bytes. It is exact while
    every other writer of the file only appends. A writer that cuts the
    file's tail and appends the same number of bytes during the failed
    call leaves the expected length, and its bytes are then removed.

    {2 Lines}

    A caller that writes lines asks for {!At_line_start}. {!run} then reads
    the file's last byte before it writes. When the file ends in the middle
    of a line, the append writes a newline first, so its lines never join
    onto bytes an earlier writer left unfinished, including bytes a failed
    write of this module did not remove. The newline belongs to the same
    write as the content and is removed with it when that write fails.

    The last byte is read from the file on every such call and nothing about
    the file's end is remembered between calls. A remembered end would be
    wrong after another descriptor changed the file, and no cheaper check
    than the read tells whether one did.

    {2 Other writers}

    The caller serializes the appends of one path inside this process (the
    per-path append mutex). Another descriptor on the same file is not
    covered by it: another process, or this process through another name
    of the file (a hard link, a symlinked file name, a different spelling
    on a file system that folds case or normalizes names). {!run} takes no
    file lock, so against such a writer two gaps remain, each as wide as
    the two system calls involved:

    - between reading the file's length and writing, the other writer may
      leave an unfinished line that this call then joins: the last byte is
      read at the length that was read first;
    - between checking the file's length and truncating, the other writer
      may append a row that the truncation then removes.

    Outside those gaps an append by another writer during a failed call is
    seen in the file's length, and the failed call removes nothing. *)

(** What the append writes to. *)
type target = private
  | Regular_file of Unix.file_descr
    (** A regular file, open for reading and writing. It has a last byte
        that can be read and an end that can be cut. *)
  | Stream of Unix.file_descr
    (** A FIFO, socket, terminal or device, open for writing. Bytes written
        to it cannot be taken back and it has no last byte to read, so the
        content is written as it is. *)

(** Opens [path] for appending, creating a regular file when nothing is
    there. A path that already names something other than a regular file is
    opened for writing only, as the append always opened it: opening a FIFO
    for reading too would stop the open from waiting for its reader. The
    kind is taken before the open and checked on the open descriptor;
    when the two differ the open is done again, so the result's kind
    always matches how its descriptor was opened.

    A regular file must be readable as well as writable. This includes a
    path such as [/dev/stdout] on macOS while it is redirected to a
    regular file that the process holds for writing only.
    @raise Unix.Unix_error when the path cannot be examined or opened. *)
val open_target : string -> target

val descriptor : target -> Unix.file_descr

(** The descriptor operations {!run} performs on a regular file. They are
    arguments so a test can make one of them fail. *)
type io =
  { write : Unix.file_descr -> string -> int -> int -> int
    (** [write fd content offset length], as
        [Unix.single_write_substring]: one attempt that returns how many
        bytes it wrote, and has written none when it raises. {!run}
        counts the bytes to remove from these results, so a [write]
        that raises after writing some bytes breaks the rollback. It
        must not raise [Eio.Cancel.Cancelled]: that exception leaves
        {!run} at once, without the rollback. *)
  ; end_offset : Unix.file_descr -> int
    (** Moves the descriptor to the end of the file and returns that
        offset, which is the file's length. *)
  ; last_byte : Unix.file_descr -> size:int -> char option
    (** The byte at [size - 1], or [None] when the file has no byte there:
        it became shorter after [size] was read. {!run} then reads the
        length again. *)
  ; truncate : Unix.file_descr -> int -> unit
    (** [truncate fd length], as [Unix.ftruncate]. *)
  }

val unix_io : io

(** Where an append to a regular file begins. *)
type start =
  | Anywhere
    (** Right after the file's last byte, whatever that byte is. *)
  | At_line_start
    (** On a new line. When the file is not empty and its last byte is not
        a newline, a newline is written before the content. *)

(** Why {!run} did not remove the bytes of a failed write. *)
type not_rolled_back =
  | Not_a_regular_file
  | Changed_by_another_writer of
      { expected_size : int (** length before the call plus bytes written *)
      ; size : int
      }
    (** The file is longer or shorter than this call alone would have
        left it. When it is shorter, some or all of the call's bytes are
        no longer in it. *)
  | Rollback_error of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }

(** What became of the bytes a failed append had already written. *)
type rollback =
  | Nothing_written
  | Rolled_back of { bytes : int }
  | Not_rolled_back of
      { bytes : int
      ; reason : not_rolled_back
      }

type failure =
  | End_unreadable of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }
    (** The end of a regular file could not be read. Nothing was written. *)
  | Last_byte_missing of { size : int }
    (** The file stayed [size] bytes long and still had no byte at
        [size - 1]. Nothing was written. *)
  | Write_failed of
      { write_failure : Fd_write_all.failure
      ; rollback : rollback
      }

(** [run ~io ~start target content] appends all of [content] or reports why
    it could not. An empty [content] writes nothing, not even the newline of
    {!At_line_start}.

    On a regular file a successful {!Anywhere} append costs one
    [end_offset] and the write; an {!At_line_start} append also reads the
    last byte. The second [end_offset] and the truncation happen only after
    a failed write. On a stream the append is the write alone and [start]
    has no effect. *)
val run : io:io -> start:start -> target -> string -> (unit, failure) result

val failure_to_string : failure -> string
