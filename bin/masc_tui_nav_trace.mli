(** The events the opt-in navigation trace writes (RFC-0485).

    Two things earn a line: a frame that drew another screen than the one
    before it, and a key after which the frame was the same as the one before.
    The second is how a footer that announces a key the screen does not act on
    shows up without a person pressing every key on every screen.

    No clock, no file and no terminal here: the caller hands in what the loop
    already knows and writes the line this returns.

    What the trace may hold of a key is decided by the type. A word for a key
    that is not text (the decoder's [left] and [pageup], a control byte's
    [ctrl-w]) is kept. A character is kept only as the footer's own spelling of
    a key it announced; every other character is {!Other_char}, which has no
    field for its value. *)

type key =
  | Named of { name : string; advertised : bool }
      (** A key that is not text. [advertised] says whether the footer named
          it. *)
  | Advertised_char of string
      (** A character the footer announced, in the footer's spelling. Never the
          text of a draft: a letter typed into a field arrives here only when
          that screen's footer announces the same letter. *)
  | Other_char
      (** Every other character. Its value is not kept. *)

type event =
  | Surface_opened of { from : string option; to_ : string }
  | Key_unchanged of { surface : string; key : key }

val observe :
  previous_surface:string option ->
  surface:string ->
  key:string option ->
  result:Masc_tui_frame_presenter.present_result ->
  advertised:string list ->
  event list
(** What the frame just presented adds to the trace. [previous_surface] is the
    surface key of the frame before it ([None] for the first frame), [surface]
    its own, and [key] the [Key] the input decoder delivered since that frame
    ([None] when the input was a paste, a mouse report, a terminal reply or
    nothing). [advertised] holds the keys the footer announced for the frame,
    one atom each, in the footer's spelling (the atoms
    [Masc_tui_footer.advertised_key_atoms] reads out of a hint string).

    The surface event comes first. A key is reported only when the frame
    presented nothing: a key that changed the screen needs no line. *)

val to_json_line : at:float -> event -> string
(** One JSON object, without a newline. [at] is the caller's clock reading in
    seconds. *)
