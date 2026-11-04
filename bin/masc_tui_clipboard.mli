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

(** {1 Copying text out}

    Text the operator copies goes to a desktop clipboard tool when this
    process may run where the operator pastes, and to the terminal as OSC 52
    otherwise or when no tool takes it. A tool's exit status says whether the
    text arrived; OSC 52 says nothing back, so its outcome stays unconfirmed. *)

type writer

val writers : writer list
(** The tools {!copy_text} tries, in order: pbcopy, wl-copy, xclip. Each reads
    the text from a file and prints nowhere. *)

val writer_name : writer -> string

type copy_session =
  | Local  (** this process runs where the operator pastes *)
  | Multiplexed
      (** inside tmux: the operator may have attached from another machine
          since this process started *)
  | Remote  (** over SSH: a tool here would fill this host's clipboard *)

val copy_session : (string -> string option) -> copy_session
(** [Remote] when the environment names an SSH connection or SSH terminal,
    [Multiplexed] when it names a tmux server, [Local] otherwise. *)

type copy_route =
  | Through_tools of
      { first : writer
      ; rest : writer list
      ; also_terminal : bool  (** the terminal gets the text as well *)
      }  (** installed tools, tried in order until one takes the text *)
  | Terminal_only

val copy_route : copy_session -> installed:(string -> bool) -> copy_route
(** Where a copy goes before anything runs. *)

type terminal_reason =
  | Not_tried  (** no tool may reach the operator's clipboard *)
  | Tools_failed of string * string list
      (** every installed tool failed or could not start, in the order tried *)
  | Not_staged of string  (** the file the tools read could not be written *)

type copy_outcome =
  | Copied_by of string  (** this tool exited 0 with the text *)
  | Copied_by_and_sent_to_terminal of string
      (** this tool exited 0, and the text was also written as OSC 52 *)
  | Sent_to_terminal of terminal_reason  (** written as OSC 52 only *)

val copy_text :
  copy_session -> write_osc52:(string -> unit) -> string -> copy_outcome
(** Copy [text] along {!copy_route}, falling back to [write_osc52] when no
    tool takes it. Runs each tool synchronously; the call returns once one has
    taken the text or all have failed. Raises nothing of its own. *)

val copy_outcome_text : copy_outcome -> string
(** What happened, for the operator's notice. *)

val copy_outcome_text_korean : copy_outcome -> string
(** The same, as the end of a Korean notice that has named what was copied. *)
