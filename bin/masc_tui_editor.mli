(** $EDITOR round-trip for a JSON settings payload. See the implementation
    for the terminal-handshake contract. *)

val editor_command : unit -> string option
(** The operator's editor: [$EDITOR] first, [$VISUAL] as fallback, [None]
    when neither is set to a non-empty value — the caller reports that no
    editor is configured rather than guessing one. *)

val roundtrip :
  restore:(unit -> unit) -> reenter:(unit -> unit) -> string -> string option
(** [roundtrip ~restore ~reenter content] hands [content] to the editor and
    returns [Some edited] on exit code 0, [None] otherwise. [restore] runs
    before the child (leave raw mode), [reenter] after it (raw mode back,
    full repaint requested). *)
