(** The turning imp ({!Masc_tui_imp_emblem}) laid out as the body rows of a
    screen, under a few lines of caption. The startup splash and [/about]
    both draw it through here, so the two keep one size rule, one motion rule
    and one pace. *)

type drawn =
  | Moving  (** The last frame drew the imp turning. *)
  | Still  (** The last frame drew the imp held at {!Masc_tui_imp_emblem.settled}. *)
  | Absent  (** The last frame drew no imp. *)

val moves : colors_enabled:bool -> Masc_tui_imp_emblem.backdrop -> bool
(** Whether the imp turns. Only with colour on and a page the terminal
    described: under NO_COLOR, or on a page nothing is known about, the dots
    alone would shimmer without shading, so the imp is held still. *)

val rows :
  cols:int ->
  rows:int ->
  caption:string list ->
  elapsed:float ->
  colors_enabled:bool ->
  backdrop:Masc_tui_imp_emblem.backdrop ->
  drawn * string list
(** The body: the imp centred in [cols] x [rows] with [caption] centred under
    it, one blank row between, the block centred top to bottom. [elapsed] is
    how long the imp has been turning, in seconds; it is read against
    {!Masc_tui_imp_emblem.loop_seconds}, and a negative one is the start. When the
    space is too small for the imp ({!Masc_tui_imp_emblem.fit} is [None]),
    the caption is drawn alone and the answer is [Absent]. The imp is inked
    through {!Masc_tui_imp_emblem.stdout_ink}, the TUI's own colour
    projection, so NO_COLOR and a terminal without colour get bare dots.
    Caption lines may carry the renderer's own colour escapes; they are
    measured without them. No row is wider than [cols] display cells. *)

val body : cols:int -> rows:int -> caption:string list -> elapsed:float -> string list
(** {!rows} against this process: the page the terminal reported -- both
    colours, only light or dark, or nothing -- and the TUI's colour setting.
    Records what it drew for {!drawn}. *)

(** How many Keepers /about can say the workspace holds. *)
type keeper_count =
  | Keepers_read of int  (** The roster was read; [0] is a known empty one. *)
  | Keepers_unreadable  (** The roster could not be read. *)
  | Keepers_unread  (** The roster has not been read yet: no count, not none. *)

val about_facts : theme:string -> keeper_count -> string
(** The fact line under the imp on /about: the colour scheme in use and the
    Keeper count, each only as far as it was read. *)

val begin_frame : unit -> unit
(** Called once for every frame, drawn or skipped: a frame that calls {!body}
    records the imp; one that does not -- including one skipped because a
    picture owns the terminal -- leaves {!Absent}. *)

val drawn : unit -> drawn
(** What the last frame drew. The main loop steps the imp only while this is
    {!Moving}, so a screen without a turning imp stops repainting for it. *)
