(** Streams directly under the root storage of a Compound File Binary file
    ([MS-CFB]), the container of DOC, XLS, PPT, HWP and encrypted Office Open
    XML.

    Every sector chain is followed with a visited set, so a cyclic chain is a
    {!Chain_cycle} and a pointer past the end of the file is a {!Bad_sector};
    neither loops or raises. *)

val signature : string
(** [D0 CF 11 E0 A1 B1 1A E1]. *)

type fault =
  | Truncated_header
  | Bad_header of string
      (** Byte order, version, sector size, or a count the file cannot hold. *)
  | Bad_sector of { sector : int }
      (** A chain names a reserved value or a sector outside the file. *)
  | Chain_cycle of { start : int }
  | Bad_directory of string
      (** The root entry is missing, a stream declares more bytes than the
          file holds, or the sibling tree under the root revisits an entry
          (the root included) or names one that does not exist. *)
  | Short_stream of
      { name : string
      ; declared : int
      ; read : int
      }
      (** The chain ends, or the file cuts a sector short, before the bytes
          asked for. [read] counts the stream bytes before the gap. *)

type t

val read : string -> (t, fault) result
(** [read bytes] parses the header, the FAT, the mini FAT and the directory. *)

val root_streams : t -> string list
(** The names of the streams directly under the root storage. Streams inside
    a storage, such as an embedded object, are not listed. *)

val stream_slice :
  t -> string -> offset:int -> max_bytes:int -> (string option, fault) result
(** [stream_slice t name ~offset ~max_bytes] is the bytes of the root stream
    called [name] from [offset], at most [max_bytes] of them and none past
    the stream's declared size: shorter than [max_bytes] only when the stream
    ends first. A negative [offset] or [max_bytes] counts as [0]. [MS-CFB]
    names ignore case, so the comparison ignores ASCII case. [None] when the
    root has no such stream.

    Only the sectors up to the slice's end are followed. A chain that ends,
    or a sector the file cuts short, before then is {!Short_stream}. *)
