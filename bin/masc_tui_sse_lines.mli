(** The lines of a byte stream that arrives in chunks, such as a server-sent
    event stream read off a socket.

    A line ends at ['\n'] and is returned without it; a ['\r'] before the
    newline stays in the line. Bytes after a chunk's last newline are held
    until a later chunk ends their line. Each chunk is scanned once and each
    line is copied once, so a line that arrives over many chunks costs its own
    length rather than its length times the number of chunks. *)

type t

val create : unit -> t

val feed : t -> string -> string list
(** [feed t chunk] returns the lines [chunk] completes, in the order they
    ended. An empty line between two newlines is returned as [""]. *)
