(** Double-buffered differential ANSI presenter with CSI 2026 synchronized
    output, dirty-run coalescing (bridging <= 3 clean cells), wide-glyph dirty
    coupling, stateful SGR deltas, trailing blank [\x1b[K] optimization, and a
    reusable 64 KiB output buffer. *)

type capabilities = {
  synchronized_output : bool;   (** CSI 2026: [\x1b[?2026h] .. [\x1b[?2026l] *)
  color_depth : Color.depth;
  braille_safe : bool;
  unicode_blocks : bool;
  osc8_hyperlinks : bool;
  osc52_clipboard : bool;
  kitty_keyboard : bool;
  graphics : Probe.graphics_reply option;
      (** Observed Kitty graphics probe reply, or [None] when unreported. *)
  cell_pixels : (int * int) option;
      (** Observed CSI 16t terminal cell dimensions [(width_px, height_px)]. *)
}

type cursor_shape =
  | Block
  | Bar
  | Underline

type cursor = {
  x : int;
  y : int;
  visible : bool;
  shape : cursor_shape;
}

type diff_stats = {
  dirty_cells : int;
  dirty_runs : int;
  bytes_emitted : int;
  diff_us : int;
  full_repaint : bool;
}

type t

val default_capabilities : capabilities
val apply_probe_observation : Probe.observation -> capabilities -> capabilities
(** Merge observed {!Probe.observation} graphics and cell pixel dimensions into
    [capabilities] without discarding previously observed values. *)

val hidden_cursor : cursor

val create : cols:int -> rows:int -> capabilities:capabilities -> t
val capabilities : t -> capabilities
val set_capabilities : t -> capabilities -> unit

val back_grid : t -> Cell_grid.t
(** Preallocated back framebuffer owned by [t]. Clear and draw into it, then
    call {!present_back} for an O(1) zero-reallocation front/back swap. *)

val front_grid : t -> Cell_grid.t
(** The last presented framebuffer owned by [t] (read-only; used to extract
    settled mouse-selection text). *)

val resize : t -> cols:int -> rows:int -> unit
val invalidate : t -> unit
(** Force a full repaint on the next present (e.g. after [Terminal_out.take_lost]
    or SIGCONT). *)

val present_back :
  t -> cursor:cursor -> write:(string -> unit) -> diff_stats
(** Diff {!back_grid} against the presented front grid, emit synchronized ANSI
    via [write], and swap front/back buffers in O(1). Emits zero bytes and skips
    [write] when identical to the previous frame and cursor. *)

val present :
  t -> grid:Cell_grid.t -> cursor:cursor -> write:(string -> unit) -> diff_stats
(** Diff an external [grid] against the presented front grid, emit synchronized
    ANSI via [write], and retain a copy in the front buffer. *)
