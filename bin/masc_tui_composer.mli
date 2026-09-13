(** The composer row every surface carries on its last terminal line.

    It is one row, always drawn, and it answers two questions before a key is
    ever pressed: which keeper a message would reach, and whether it could be
    sent at all. Those are the two facts an operator cannot recover after the
    fact, and the roster surface is where the answer changes under them — the
    cursor moves on its own when a refresh drops a row.

    Focus is separate from presence. The surfaces bind single letters to
    lifecycle and navigation, so a row that swallowed every printable key would
    take [p] from pause; the operator takes focus explicitly and the row says
    how. Nothing here performs I/O or reads the terminal. *)

(** What the composer can do for the keeper it is pointed at. *)
type target =
  | No_target
      (** No keeper is selected — an empty roster, or a surface reached before
          one ever was. *)
  | Unreachable of {
      keeper : string;
      reason : string;
    }
      (** A keeper is named but a message cannot be sent to it, and this is
          why. The name is kept rather than cleared: an operator who typed a
          draft for it needs to see which keeper went away, not an empty row. *)
  | Ready of string

(** Whether the row is taking keystrokes. *)
type focus =
  | Unfocused
  | Focused

type t = {
  target : target;
  focus : focus;
  draft : string;
  staged_images : int;
      (** Images staged with [/attach] and not yet sent. Rendered in the prompt
          because the draft alone does not show them: an operator who attaches,
          types for a while, and sends would otherwise have no way to see what
          leaves with the message. *)
}

val rows_for : terminal_rows:int -> int
(** Terminal rows the composer occupies in this viewport. Every surface lays
    its frame out against this many rows fewer than the terminal has.

    Zero on a viewport that has no row to spare. A surface pushed under the
    fixed-chrome budget shows a resize gate instead of itself, so a convenience
    row that costs the surface is worse than no row: the composer yields. *)

val focus_key : string
(** The key that moves focus into the composer from any surface. *)

val release_key : string
(** The key that returns focus to the surface. *)

val continuous_key : string
(** The key that turns continuous capture on and off from a focused row.
    Ctrl-A, chosen for the same reason as {!listen_key}: a focused row spends
    every printable key on draft text. *)

val send_key : string
(** The key {!classify_key} answers {!Send} for. Exposed so a caller that must
    send without a keypress hands this to {!classify_key} rather than calling
    the send path itself. *)

val listen_key : string
(** The key that starts a microphone capture from a focused row. Ctrl-Y.

    Every printable key in a focused row is draft text, so this cannot be a
    letter without taking it from typing. Ctrl-Y is the one control code this
    TUI does not already spend. *)

val prompt : t -> string
(** The label before the draft: who the message would reach, or why it could
    not be sent. Plain text — the caller styles and fits it. *)

val accepts_input : t -> bool
(** Whether a keystroke should reach the draft. False when the row is
    unfocused, and false when there is nothing to send to, so a draft cannot
    be typed into a row that has no recipient. *)

val can_send : t -> bool
(** Whether the draft can be dispatched: a reachable target and a draft that is
    not only whitespace. *)

(** What a keypress does to the composer. *)
type key_outcome =
  | Take_focus
  | Release_focus
  | Send
  | Start_listening
      (** The row asks for a microphone capture. Classification only — this
          module performs no I/O, and the caller runs the capture and puts the
          transcript in the draft. *)
  | Toggle_continuous
      (** The row asks to start or stop capturing repeatedly. The caller holds
          that mode; this only reports the keypress. *)
  | Edit
      (** The key belongs to the draft; the caller applies it to the buffer. *)
  | Pass_to_surface
      (** The key is not the composer's; the surface handles it as before. *)

val classify_key : t -> string -> key_outcome
(** Route one keypress. An unfocused composer claims only {!focus_key}, and
    only when it has somewhere to send; everything else reaches the surface, so
    no existing binding changes while the row sits idle. *)

val cursor_column : prompt_cells:int -> draft_cells:int -> terminal_cols:int -> int
(** One-based terminal column for the text cursor, clamped inside the row. *)
