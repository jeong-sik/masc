(** The image on the system clipboard, as bytes.

    A terminal never delivers a pasted image. Bracketed paste carries text, and
    a clipboard holding a screenshot has no text form to send -- which is why
    Ctrl-V in this composer had nothing to work with even once the key itself
    stopped being swallowed by the tty layer ({!Masc_tui_termios}). The bytes
    have to be fetched from the clipboard directly, through whichever reader
    this desktop has.

    What comes back is bytes and nothing else: staging, size limits, and media
    type are {!Masc_tui_attachment}'s, so a clipboard image and a dropped file
    are accepted or refused on the same terms. *)

type error =
  | No_reader of { tried : string list }
      (** No clipboard reader is installed. [tried] names what was looked
          for, so the operator learns which one to install rather than that
          "paste failed". *)
  | No_image of { reader : string }
      (** The reader ran and the clipboard holds no image. Copied text
          arrives here: it is a normal answer to Ctrl-V, not a fault. *)
  | Unreadable of { reader : string; detail : string }
      (** The reader ran, reported success, and left nothing usable. *)

val read_image : unit -> (string, error) result
(** Read the clipboard's image bytes.

    Readers are tried in order and the first installed one that returns bytes
    wins. On a Linux desktop both a Wayland and an X11 reader can be present
    while only one of them can see the running session's clipboard, so a
    reader that answers "no image" is not the end of the search. *)

type reader

val readers : reader list
(** The readers {!read_image} tries, in the order it tries them. *)

val reader_name : reader -> string
(** The executable this reader needs on PATH. *)

val reader_command : reader -> dest:string -> string
(** The shell command that puts the clipboard image into [dest].

    Exposed because the quoting is the part that fails silently: a command
    whose path escaped wrong reports "no image" for a clipboard that has one,
    and that is indistinguishable from success at the call site. *)

val error_to_string : error -> string
(** One line an operator can act on. *)
