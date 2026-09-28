(** The turning imp ({!Masc_tui_imp_emblem}) laid out as the body rows of a
    screen, under a few lines of caption. The startup splash and [/about]
    both draw it through here, so the two keep one size rule, one motion rule
    and one pace. *)

type drawn =
  | Moving  (** The last frame drew the imp turning. *)
  | Still  (** The last frame drew the imp held at {!Masc_tui_imp_emblem.settled}. *)
  | Absent  (** The last frame drew no imp. *)

val step_seconds : float
(** How far one step of the main loop moves the imp. *)

val step_ns : int64
(** {!step_seconds} in nanoseconds, the unit the main loop's clock reads. *)

val backdrop :
  Masc_tui_terminal_palette.snapshot -> Masc_tui_imp_emblem.backdrop
(** What the terminal said about its page: both colours, only light or dark,
    or nothing. *)

val moves : colors_enabled:bool -> Masc_tui_imp_emblem.backdrop -> bool
(** Whether the imp turns. Only with colour on and a page the terminal
    described: under NO_COLOR, or on a page nothing is known about, the dots
    alone would shimmer without shading, so the imp is held still. *)

val rows :
  cols:int ->
  rows:int ->
  caption:string list ->
  frame:int ->
  colors_enabled:bool ->
  backdrop:Masc_tui_imp_emblem.backdrop ->
  drawn * string list
(** The body: the imp centred in [cols] x [rows] with [caption] centred under
    it, one blank row between, the block centred top to bottom. [frame] is
    the main loop's step count; a negative one is the first step. When the
    space is too small for the imp ({!Masc_tui_imp_emblem.fit} is [None]),
    the caption is drawn alone and the answer is [Absent]. The imp is inked
    through {!Masc_tui_imp_emblem.stdout_ink}, the TUI's own colour
    projection, so NO_COLOR and a terminal without colour get bare dots.
    Caption lines may carry the renderer's own colour escapes; they are
    measured without them. No row is wider than [cols] display cells. *)

val body : cols:int -> rows:int -> caption:string list -> frame:int -> string list
(** {!rows} against this process: the palette the terminal reported and the
    TUI's colour setting. Records what it drew for {!drawn}. *)

(** How many Keepers /about can say the workspace holds. *)
type keeper_count =
  | Keepers_read of int  (** The roster was read; [0] is a known empty one. *)
  | Keepers_unreadable  (** The roster could not be read. *)
  | Keepers_unread  (** The roster has not been read yet: no count, not none. *)

val about_facts : theme:string -> keeper_count -> string
(** The fact line under the imp on /about: the colour scheme in use and the
    Keeper count, each only as far as it was read. *)

val begin_frame : unit -> unit
(** Called once at the start of every frame: a frame that calls {!body}
    records the imp; one that does not leaves {!Absent}. *)

val drawn : unit -> drawn
(** What the last frame drew. The main loop steps the imp only while this is
    {!Moving}, so a screen without a turning imp stops repainting for it. *)
