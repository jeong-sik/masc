(** The lines of a byte stream that arrives in chunks, such as a server-sent
    event stream read off a socket.

    A line ends at ['\n'] and is returned without it; a ['\r'] before the
    newline stays in the line. Bytes after a chunk's last newline are held
    until a later chunk ends their line. Each chunk is scanned once, and the
    bytes of a held line are copied into the reader and out again when it
    ends, so the cost of a line grows with its own length. Each reader holds
    its own unfinished line. *)

type t

val create : unit -> t

val feed : t -> string -> string list
(** [feed t chunk] returns the lines [chunk] completes, in the order they
    ended. An empty line between two newlines is returned as [""]. *)
