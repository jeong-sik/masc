(** MASC's candle ({!Keeper_portrait_look.mascot}) for [/about].
    {!Masc_tui_portrait_view} chooses real pixels, a half-block mosaic,
    or no picture from the terminal capabilities. *)

type drawn =
  | Moving  (** The last frame drew the candle, flickering and blinking. *)
  | Absent  (** The last frame drew no candle. *)

type laid_out = {
  drawn : drawn;
  lines : string list;  (** the body, at most [rows] rows of at most [cols] cells *)
  placement : Masc_tui_portrait_view.placement option;
      (** where real pixels go, for a {!Masc_tui_portrait_view.Pixels}
          display; [None] for a mosaic, which is in [lines] already *)
}

val rows :
  cols:int ->
  rows:int ->
  caption:string list ->
  elapsed:float ->
  display:Masc_tui_portrait_view.display ->
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  origin:int * int ->
  laid_out
(** The body: the candle fitted within [cols] x [rows], with [caption]
    centred under it and one blank row between, the block centred top to bottom.
    [elapsed] is how long the candle has been on screen, in seconds; it
    picks the pose ({!Keeper_portrait_draw.pose_at}), a negative one is the
    start and one that is not finite is the still pose. [origin] is the frame
    line and cell of the body's top-left corner, so a placed picture lands on
    the rows the body left for it. When the display draws no picture, or the
    space is too small for one ({!Masc_tui_portrait_view.fit} is [None]),
    the caption is drawn alone and the answer is [Absent]. Caption lines may
    carry colour escapes; they are measured without them. *)

val body :
  cols:int -> rows:int -> caption:string list -> elapsed:float -> origin:int * int -> string list
(** {!rows} against this process: the display the start-up probe chose and
    the stdout colour projection. Records what it drew for {!drawn}, and asks
    {!Masc_tui_portrait_view.request} for the placed picture. *)

(** How many Keepers /about can say the workspace holds. *)
type keeper_count =
  | Keepers_read of int  (** The roster was read; [0] is a known empty one. *)
  | Keepers_unreadable  (** The roster could not be read. *)
  | Keepers_unread  (** The roster has not been read yet: no count, not none. *)

val about_facts : theme:string -> keeper_count -> string
(** The fact line under the candle on /about: the colour scheme in use and
    the Keeper count, each only as far as it was read. *)

val begin_frame : unit -> unit
(** Called once for every frame, drawn or skipped: a frame that calls {!body}
    records the candle; one that does not -- including one skipped because a
    picture owns the terminal -- leaves {!Absent}. *)

val drawn : unit -> drawn
(** What the last frame drew. The main loop steps the candle only while this
    is {!Moving}, so a screen without the candle stops repainting for it. *)
