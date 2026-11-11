(** How {!Keeper_cleanup_status.t} is published and read.

    The server writes the value on the dashboard tools envelope and the TUI
    reads it. Both go through this module, so a field has one name. *)

open Keeper_cleanup_status

val envelope_field : string
(** The dashboard tools envelope field that carries this value. *)

val to_json : t -> Yojson.Safe.t

(** What a reader made of a published value. The server and its reader can be
    different builds, and steps are added over time, so the summary and each
    row are read on their own: a part this build cannot read is kept as its
    reason, and the parts beside it are still read. Nothing unknown is read
    as something known. *)
type reading =
  { read_pass : (pass option, string) result
  (** The latest pass, [Ok None] before the first one after a start, or why
      the summary could not be read. *)
  ; read_rows : row list  (** The rows that were read, in the order sent. *)
  ; unread_rows : string list
  (** One reason for each row that could not be read, in the order sent. *)
  ; unknown_fields : string list
  (** Fields of the value itself that this build does not know. *)
  }

val read_json : Yojson.Safe.t -> (reading, string) result
(** Reads what {!to_json} wrote. A summary or a row is refused for a missing,
    duplicate or unknown field, a value of the wrong kind, a negative count,
    an unknown outcome, and a step this build does not know. [Error] when the
    value is not an object, repeats a field, or carries no list of rows: then
    no part of it can be told from another. *)
