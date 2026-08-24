(** A paste too big to hold in the composer.

    The composer is five rows. A paste of four hundred lines is not something
    an operator can read there, and a draft they cannot read is a message they
    cannot check before sending. The text is kept whole and the draft carries
    a line that says what is in it and what the keeper will find on disk.

    Pure: decides and describes. The writing is the caller's. *)

type t = {
  text : string;  (** What was pasted, unchanged. *)
  lines : int;
  bytes : int;
  file_name : string;
      (** What the file is called inside the keeper's own directory. A bare
          name, no directories: a keeper reads paths relative to its sandbox
          root, and a name is the only shape that is the same on the host and
          inside a container. *)
}

val inline_max_lines : int
(** Above this many lines a paste is spilled. Tied to what the composer can
    show: past it the operator is editing text they cannot see. *)

val inline_max_bytes : int
(** Above this many bytes a paste is spilled however few lines it has -- one
    line can be a whole minified file. *)

val of_paste : now_iso:string -> nonce:string -> string -> t option
(** [None] when the paste fits in the draft and should simply be typed into
    it. [now_iso] and [nonce] name the file; both are the caller's, so this
    stays a function of its arguments and a test can name a file exactly. *)

val draft_line : t -> string
(** What stands in the draft where the text would have been. One line, so the
    composer shows it whole, and it says the size so an operator can tell a
    stray paste from the one they meant. *)

val message_line : t -> string
(** What goes to the keeper in place of the text: the file name, what is in
    it, and where to look. The keeper reads paths relative to its own
    directory, so the name is given bare and said to be there. *)

val substituted : t -> replacement:string -> string -> string option
(** Put [replacement] where {!draft_line} stands in the draft.

    [None] when the line is not there. An operator who deleted the placeholder
    meant to drop the paste, and putting it back somewhere of this function's
    choosing would send text they had removed. *)
