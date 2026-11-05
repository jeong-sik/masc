(** The file [MASC_TUI_NAV_TRACE] names (RFC-0485).

    Off unless the variable names a file; a blank value is off, as it is for
    [MASC_TUI_FRAME_TIMING]. While off, every call below returns at once: no
    clock is read and no file is opened. While on, the file is opened at the
    first line, appended to, and flushed after each line, so a reader that
    follows it sees a key a moment after the press.

    [Masc_tui_nav_trace] decides what a line holds. This module carries what
    the loop knows between calls -- the surface of the frame before, the key
    pressed since -- and the file. *)

type t

val create : path:string -> max_lines:int -> clock:(unit -> float) -> t
(** A trace that appends to [path]. After [max_lines] lines it writes one
    [capped] line and nothing more. A [path] that cannot be opened, or a write
    that fails, ends the trace without raising: a diagnostic must not take the
    process down. [clock] is read once per line. *)

val from_environment : clock:(unit -> float) -> t
(** [create] on the path [MASC_TUI_NAV_TRACE] holds, with a 4096 line cap, or
    the off trace when the variable is absent or blank. *)

type input =
  | Key of string
      (** A key the input decoder delivered, spelled the way it spells it. *)
  | Other_input
      (** A paste or a pointer event: the input since the last frame was not a
          key. *)
  | No_input
      (** No operator input: nothing was read, or the terminal answered a
          question. A key still waiting for its frame stays. *)

val note_input : t -> input -> unit
(** The loop read this input. A later key replaces an earlier one that no frame
    has been presented for, and a paste or pointer event drops it. *)

val announce : string -> unit
(** The footer line was asked to show these key hints. Kept process-wide
    because the footer is drawn deep inside the render and the frame record has
    no field for it. [note_frame] reads what the last footer line announced
    and forgets it, so a frame that draws no footer announces nothing. *)

val note_frame :
  t -> surface:string -> result:Masc_tui_frame_presenter.present_result -> unit
(** A frame of [surface] was presented, with this result. Writes the surface
    event and the key event [Masc_tui_nav_trace.observe] decides on, for the
    key [note_input] saw and the hints [announce] saw since the frame
    before. *)
