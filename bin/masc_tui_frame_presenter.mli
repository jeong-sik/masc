type cursor =
  | Hidden
  | Visible_at of {
      row : int;
      column : int;
    }

type frame = {
  surface_key : string;
  compact_frame : bool;
  terminal_rows : int;
  terminal_cols : int;
  cursor : cursor;
  lines : string list;
}

type present_result =
  | Presented
  | Unchanged

type t

val create : synchronized_output:bool -> unit -> t
val invalidate : t -> unit
val last_frame_is_compact : t -> bool
(** Whether the last successfully presented frame was the compact fallback.
    Before the first frame and after invalidation this is conservatively
    [true], so input cannot act on a surface the terminal has not shown. *)

val setup : t -> write:(string -> unit) -> flush:(unit -> unit) -> unit
(** Take the alternate screen and discard the cached screen, so the next
    [present] paints every row. Call before the first frame, and again after
    anything that hands the terminal back -- a resumed SIGTSTP re-enters here. *)

val cleanup : t -> write:(string -> unit) -> flush:(unit -> unit) -> unit
(** Best-effort idempotent terminal recovery: end synchronized output, reset
    style, show the cursor, restore autowrap, and give the alternate screen
    back. Leaving it restores what the shell had, so nothing is cleared here --
    clearing would take the scrollback the caller is being handed back. The
    synchronized-output end marker follows the presenter's configured policy. *)

val present :
  t ->
  invalidate_before:bool ->
  write:(string -> unit) ->
  flush:(unit -> unit) ->
  frame ->
  present_result
(** Present one fixed-viewport frame with at most one [write] and one [flush].
    [invalidate_before] discards the cached screen before comparison, coupling
    out-of-band terminal writes to the next full redraw.
    Content updates compare opaque ANSI rows byte-for-byte. Cursor-only moves
    remain differential and are emitted in the same atomic output buffer.
    [Presented] means the terminal accepted output for this frame;
    [Unchanged] means no bytes were necessary, so semantic input authority
    must remain with the last frame that was actually emitted. *)

type scheme =
  { foreground : Masc_tui_terminal_palette.rgb
  ; background : Masc_tui_terminal_palette.rgb
  ; ansi : Masc_tui_terminal_palette.rgb option array
        (** One entry per colour code, [Masc_tui_terminal_palette
            .ansi_slot_count] of them. [None] leaves that slot as the reader
            has it. A shorter or longer array simply carries fewer or more
            pairs; the index a colour is sent under is its position. *)
  }
(** Every colour a terminal draws masc with: the two it uses when nothing says
    otherwise, and the sixteen a colour code selects.

    They travel together because they are only meaningful against each other.
    A colour alone is a contrast ratio against a background the scheme did not
    choose, and a background alone is the one case that is worse than not
    applying the scheme at all. *)

val sync_scheme :
  write:(string -> unit) -> flush:(unit -> unit) -> scheme option -> unit
(** Ask the terminal to draw with these colours, or [None] to put all of them
    back.

    Send the whole scheme or none of it. Two ways to get this wrong, both of
    which masc has shipped:

    - Page without text. masc draws most of its text without naming a colour,
      so that text is whatever the terminal's default foreground is. A light
      scheme paints the page near-white and the reader's near-white default
      text stays on it.

    - Text and page without the sixteen. Everything masc says with colour --
      Ok, Warn, Bad, Info, who spoke, the tool trail, the receding row -- is
      drawn by naming a code, not a colour. Leave the codes behind and the
      scheme reaches the two quietest colours on the screen and nothing else.

    A terminal that does not know OSC 4, 10 and 11 ignores them, so this is
    sent without asking first. {!cleanup} resets on the way out; a caller that
    changes the scheme mid-session has to send the new colours itself. *)
