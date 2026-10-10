(** What the server's last start of the Keeper Firefox and its BiDi host
    came to (RFC-browser-keeper-firefox §3.7):
    [<base>/.masc/browser-lane/keeper-firefox-start.json], replaced whole
    each time a start ends, at a server start or for a Keeper's request.
    Only the status sentences read it; it never holds a start back. *)

type outcome =
  | Attached of Browser_keeper_firefox_starter.started
  | Not_attached of Browser_keeper_firefox_starter.not_attached

type entry =
  { at : float  (** When the start ended. *)
  ; outcome : outcome
  }

val record_path : base_path:string -> string

(** A not-attached message is kept as one printable line of at most this
    many bytes ({!Printable_line}): a server sentence can name more than one
    path, so it gets more room than a host's reason. *)
val message_limit_bytes : int

(** Writes [entry], its message as one printable line. [Error] says why it
    was not, or that it was and its directory entry was not flushed. *)
val write : base_path:string -> entry -> (unit, string) result

type read = Absent | Recorded of entry | Unreadable of string

val read : base_path:string -> read

val entry_to_json : entry -> Yojson.Safe.t

(** Takes the fields of this layout and no others, and a message only in the
    form {!write} leaves one. *)
val entry_of_json : Yojson.Safe.t -> (entry, string) result
