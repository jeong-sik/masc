type cursor =
  | Hidden
  | Visible_at of {
      row : int;
      column : int;
    }

type frame = {
  surface_key : string;
  terminal_rows : int;
  terminal_cols : int;
  cursor : cursor;
  lines : string list;
}

type t

val create : synchronized_output:bool -> unit -> t
val invalidate : t -> unit
val cleanup : t -> write:(string -> unit) -> flush:(unit -> unit) -> unit
(** Best-effort idempotent terminal recovery: end synchronized output, reset
    style, show the cursor, restore autowrap, and clear/home the screen. The
    synchronized-output end marker follows the presenter's configured policy. *)

val present :
  t ->
  invalidate_before:bool ->
  write:(string -> unit) ->
  flush:(unit -> unit) ->
  frame ->
  unit
(** Present one fixed-viewport frame with at most one [write] and one [flush].
    [invalidate_before] discards the cached screen before comparison, coupling
    out-of-band terminal writes to the next full redraw.
    Content updates compare opaque ANSI rows byte-for-byte. Cursor-only moves
    remain differential and are emitted in the same atomic output buffer. *)
