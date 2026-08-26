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
