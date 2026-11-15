(** Terminal settings this program needs that [Unix.terminal_io] cannot state.

    The record [Unix.tcsetattr] takes has no IEXTEN field and no c_cc array.
    It carries ten c_cc characters as plain [char]s, but not the value that
    turns a key off: [_POSIX_VDISABLE], 0xff on macOS and 0 on Linux. So a key
    the tty layer claims for itself cannot be reclaimed through it. That is
    not a gap worth a whole termios binding: the keys are taken at session
    start and returned at the end. *)

(** A key the tty layer takes before a raw-mode reader sees it. *)
type reclaimed_key =
  | Literal_next
      (** VLNEXT, Ctrl-V. Swallowed, and the byte after it passed through
          uninterpreted. Ctrl-V is the paste key. *)
  | Discard_output
      (** VDISCARD, Ctrl-O, on BSD terminals. The Browser screenshot key. *)
  | Delayed_suspend
      (** VDSUSP, Ctrl-Y, on BSD terminals. Read with ISIG on, it suspends the
          reader instead of arriving; on macOS it ended the TUI. Ctrl-Y is the
          speak key. *)
  | Quit
      (** VQUIT, Ctrl-backslash. Raw mode keeps ISIG on for Ctrl-C and Ctrl-Z,
          so the tty turns this byte into SIGQUIT. SIGQUIT ends the session
          without the confirmation q and Ctrl-C ask for. Turned off, the byte
          reaches the key reader as 0x1c, the key [Masc_tui_csi] already
          makes of a Kitty-protocol Ctrl-backslash, and no binding takes it.
          [kill -QUIT] still ends the session. *)

val key_char : Unix.file_descr -> reclaimed_key -> int
(** The key's current character as 0..255, or [-1] when [fd] is not a terminal
    or this platform has no such key. *)

val set_key_char : Unix.file_descr -> reclaimed_key -> int -> bool
(** Put a character back. [false] when [fd] is not a terminal, the platform has
    no such key, or the kernel refused. *)

val disable_key : Unix.file_descr -> reclaimed_key -> bool
(** Turn the key off so its byte reaches the process. [false] when [fd] is not
    a terminal, the platform has no such key, or the kernel refused: the key
    stays with the tty and nothing else about the terminal changes. *)

type snapshot
(** Every reclaimed key's character as a session found it. *)

val snapshot : Unix.file_descr -> snapshot
(** Read before the first {!reclaim}. Restoring the [Unix.terminal_io] captured
    at startup puts back only [Quit] -- the record cannot carry the others --
    so a session that skipped the pair would hand the operator back a shell
    without them. *)

val reclaim : Unix.file_descr -> unit
(** Turn off every reclaimed key. Call after every [Unix.tcsetattr], not once:
    OCaml's [tcsetattr] reads the kernel's termios and overwrites the fields
    the record names. [c_vquit] is one of them, so a record read before this
    call puts Ctrl-backslash back. *)

val restore : Unix.file_descr -> snapshot -> unit
(** Give back what {!snapshot} read, skipping keys it could not read. *)
