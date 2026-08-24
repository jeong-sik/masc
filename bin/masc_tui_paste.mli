(** The payload between a terminal's bracketed-paste markers.

    Without bracketed paste a terminal delivers a paste as the keys it looks
    like, so every newline in it is Return: a three-line paste becomes three
    messages, and a pasted Markdown block arrives as three separate sends.
    With the mode on, the terminal wraps the payload in [ESC \[ 2 0 0 ~] and
    [ESC \[ 2 0 1 ~], and this reads what is between them.

    Pure: the caller supplies the bytes. Nothing here touches a terminal. *)

type t = {
  text : string;
      (** The pasted text, with every line break as LF. Terminals write CR, LF
          or CRLF for a break depending on the emulator and on what was
          copied; the draft holds LF, and a CR left alone is sanitized to a
          space, which turns a pasted block into one long line. *)
  dropped : int;
      (** Bytes read past {!max_bytes} and discarded. Zero for a paste that
          fit. The count is carried rather than the fact, because an operator
          about to send part of a file needs to know how much is missing. *)
}

val end_marker : string
(** What closes a paste. The start marker is consumed by the escape decoder
    that dispatches here. *)

val max_bytes : int
(** How much of one paste is kept. A terminal hands over whatever was on the
    clipboard, and the draft holds it until it is sent; an accidental paste of
    a large file should not decide how much memory this process takes. *)

val read : next_byte:(unit -> char option) -> t
(** Read to {!end_marker}.

    Past {!max_bytes} the bytes are still read -- the marker has to be
    consumed, or the tail of the paste arrives as keystrokes -- and counted
    instead of kept.

    [next_byte] returning [None] ends the read: the terminal went away
    mid-paste, and what arrived is returned rather than dropped. *)

val unescaped_path : string -> string option
(** The path a paste names, when the paste is one.

    Dropping a file on a terminal — or copying it in Finder — pastes the path
    with every space backslash-escaped, because that is what a shell would
    need. The draft is not a shell, so the text that lands in it is a path
    nobody can open.

    Answers [Some] only for a single line that begins with [/] and whose
    backslashes each escape a character a shell would have escaped. Anything
    else is [None] and stays exactly as pasted: a code snippet containing
    ["\\n"], a Windows path, or prose. Unescaping those would alter bytes the
    operator meant to paste, with no way to ask for them back.

    Says nothing about whether the path exists — this module cannot reach a
    filesystem. A caller that wants that asks separately. *)
