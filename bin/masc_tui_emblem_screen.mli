(** MASC's candle ({!Keeper_portrait_look.mascot}) for [/about].
    {!Masc_tui_portrait_view} chooses real pixels, a half-block mosaic,
    or no picture from the terminal capabilities. *)

(** How the candle is drawn. The reader picks one on [/about]. *)
type style =
  | Painted
      (** The 2D portrait ({!Keeper_portrait_draw}): smooth shading, the
          flame flickering and the eyes blinking. *)
  | Dotted
      (** A small 3D figure in square dots ({!Keeper_portrait_solid}),
          swaying on its axis. Drawn as many pixels as the terminal shows it,
          up to {!Keeper_portrait_draw.max_size}, so the terminal does not
          scale its dots. *)

val style_of_string : string -> style option
(** ["painted"] or ["dotted"], as [\[tui\].candle] stores it. *)

val string_of_style : style -> string
val next_style : style -> style

type drawn =
  | Moving  (** The /about arrival still has a frame to draw. *)
  | Still  (** The /about arrival reached its final frame. *)
  | Absent  (** The last frame drew no candle. *)

type laid_out = {
  drawn : drawn;
  lines : string list;  (** the body, at most [rows] rows of at most [cols] cells *)
  placement : Masc_tui_portrait_view.placement option;
      (** where real pixels go, for a {!Masc_tui_portrait_view.Pixels}
          display; [None] for a mosaic, which is in [lines] already *)
}

val rows :
  style:style ->
  cols:int ->
  rows:int ->
  caption:string list ->
  elapsed:float ->
  display:Masc_tui_portrait_view.display ->
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  origin:int * int ->
  laid_out
(** The body: the candle fitted within [cols] x [rows], with [caption]
    centred under it and one blank row between, the block centred top to bottom,
    drawn in [style].
    [elapsed] is how long the candle has been on screen, in seconds; it
    picks the moment of the loop -- the pose
    ({!Keeper_portrait_draw.pose_at}) or the sway
    ({!Keeper_portrait_solid.mascot}) --, a negative one is the start and
    one that is not finite holds the candle still, a dotted one facing
    front. [origin] is the frame
    line and cell of the body's top-left corner, so a placed picture lands on
    the rows the body left for it. When the display draws no picture, or the
    space is too small for one ({!Masc_tui_portrait_view.fit} is [None]),
    the caption is drawn alone and the answer is [Absent]. Caption lines may
    carry colour escapes; they are measured without them. *)

val body :
  cols:int -> rows:int -> caption:string list -> elapsed:float -> origin:int * int -> string list
(** {!rows} against this process: the display the start-up probe chose, the
    {!style} the reader picked, and the stdout colour projection. Records what it drew for {!drawn}, and asks
    {!Masc_tui_portrait_view.request} for the placed picture. *)

val final_frame : int
(** Fourteen 150 ms steps: the finite /about arrival lasts 2.1 seconds. *)

type about_laid_out = {
  drawn : drawn;
  lines : string list;
  placements : Masc_tui_portrait_view.placement list;
  visible_keepers : int;
}

val about_cached_frames : unit -> int
(** At most 16 rendered candle frames, shared between visits to [/about]. *)

val about_rows :
  style:style -> cols:int -> rows:int -> caption:string list ->
  frame:int -> keepers:(string * Keeper_portrait_equipment.reading) list ->
  display:Masc_tui_portrait_view.display ->
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  origin:int * int -> about_laid_out
(** One finite arrival from the registered Keeper roster. Portraits retain
    their roster identity in Kitty and mosaic displays when equipment is observed.
    Unavailable equipment keeps the name without inventing a portrait; names that cannot fit
    appear in the +N count. The answer is still after [final_frame]. *)

val about_body :
  cols:int -> rows:int -> caption:string list -> frame:int ->
  keepers:(string * Keeper_portrait_equipment.reading) list -> origin:int * int -> string list
(** {!about_rows} using the current terminal display and portrait placements. *)

(** How many Keepers /about can say the workspace holds. *)
type keeper_count =
  | Keepers_read of int  (** The roster was read; [0] is a known empty one. *)
  | Keepers_unreadable  (** The roster could not be read. *)
  | Keepers_unread  (** The roster has not been read yet: no count, not none. *)

val about_facts : theme:string -> keeper_count -> string
(** The fact line under the candle on /about: the colour scheme in use and
    the Keeper count, each only as far as it was read. *)

val set_style : style -> unit
(** The style {!body} draws in from now on. {!Painted} until set. *)

val style : unit -> style

val begin_frame : unit -> unit
(** Called once for every frame, drawn or skipped: a frame that calls {!body}
    records the candle; one that does not -- including one skipped because a
    picture owns the terminal -- leaves {!Absent}. *)

val drawn : unit -> drawn
(** What the last frame drew. The main loop steps only {!Moving} while /about
    is open. {!Still} and a closed screen request no animation frames. *)
