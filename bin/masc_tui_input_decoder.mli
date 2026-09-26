(** Every byte the terminal sends to the TUI, read in one place.

    Keys, pastes, mouse reports and the terminal's answers to our queries all
    arrive on one stream. This decoder is the only thing that decides which is
    which, and the only thing that holds a sequence that has started but not
    finished (RFC tui-single-input-decoder).

    No I/O and no clock: the caller feeds bytes it read and says when a read
    came back empty. Everything here can be replayed byte for byte in a test. *)

type reply =
  | Palette of Masc_tui_terminal_palette.slot * Masc_tui_terminal_palette.rgb option
      (** OSC 4 / 10 / 11 answer. [None] when the slot was named but its colour
          did not parse. *)
  | Theme_mode of Masc_tui_terminal_palette.theme_mode
      (** [CSI ? 997 ; n n]: the answer to the query, or a later unasked notice. *)
  | Cell_pixels of int * int  (** [CSI 6 ; h ; w t], as (width, height). *)
  | Graphics of string
      (** The raw body after [ESC _ G], up to [ESC \\]. Never truncated: a body
          past the bound is dropped whole. *)

type event =
  | Key of string
  | Paste of Masc_tui_paste.t  (** Everything between [200~] and [201~]. *)
  | Mouse_wheel of Masc.Tui_decode.wheel_direction * int * int
  | Mouse_left_press of int * int
  | Mouse_left_release of int * int
  | Reply of reply
      (** Every reply that parses is emitted. Whether a later one replaces an
          earlier one is the consumer's decision. *)

type pending =
  | Prefix
      (** [ESC], [ESC O], [ESC _], an X10 report, or an OSC/APC body. These
          arrive in one burst; a quiet read ends them (see {!idle}), so the
          caller waits a short fixed time for their next byte. *)
  | Sequence
      (** A CSI has started and not finished. It stays held across quiet
          reads until its final byte or a Ctrl-C. *)
  | Character  (** A multi-byte UTF-8 character is missing its tail. *)
  | Pasting  (** Inside [200~], before [201~]. *)
  | Draining  (** A recovered paste's tail, dropped until [201~]. *)

type t

val create : unit -> t

val feed : t -> char -> event list
(** One byte. Most bytes produce zero or one event; a byte that ends one
    sequence and cannot belong to it may produce two. *)

val idle : t -> event list
(** The caller's read came back empty. Every [Prefix] resolves here: a lone
    [ESC], [ESC O] or [ESC _] is the Escape key; an X10 report is read from
    the bytes it has; an OSC or APC body is dropped, and one with no body yet
    is the Escape key (Alt+] and Alt+_ reach the reader this way). A CSI, a
    partial character and a paste keep waiting. *)

val pending : t -> pending option

val cancel_pending : t -> unit
(** Drop a held [Prefix] or [Sequence] without emitting it. Nothing else is
    touched. *)

val recover_paste : t -> Masc_tui_paste.t option
(** While [Pasting]: return what arrived so far and drop the rest of this
    paste up to its [201~]. [None] in any other state. *)

val abandon_draining : t -> unit
(** While [Draining]: stop dropping and read what follows as input. Once the
    end marker is lost there is no way to tell a later pasted byte from a
    typed one; this is the operator's unlock, not a guess that the tail
    ended. Nothing else is touched. *)
