(** Colour arithmetic the terminal does not do for us.

    Two measures, because they answer different questions.

    {!contrast_ratio} is WCAG 2, the number guidelines and tooling ask for. It
    is a ratio of luminances, and it overstates separation among dark colours
    -- which is most of a terminal -- so it is used as a floor to clear rather
    than as a place to make a change.

    {!oklab_lightness} is where changes are made. Oklab is Björn Ottosson's
    2020 space, in the public domain and under MIT, and is the lightness CSS
    Color 4 exposes as [oklab()]. A step in it is the same perceived step at
    every hue, so a colour can be moved until it reads without becoming a
    different colour: measured over twelve base16 schemes, lifting a failing
    token to 4.5:1 moves its hue by 5.6 degrees at worst and 0.3 at the
    median.

    Colours are {!Masc_tui_terminal_palette.rgb} so that what the terminal
    reported and what is computed from it stay one type. *)

val contrast_ratio
  :  Masc_tui_terminal_palette.rgb
  -> Masc_tui_terminal_palette.rgb
  -> float
(** WCAG 2 contrast, 1.0 to 21.0. Order does not matter. *)

val is_light : Masc_tui_terminal_palette.rgb -> bool
(** Whether a page reads as light. One definition, so the direction a colour
    has to move to be read and the way a row is set apart from the page cannot
    disagree about the same terminal. *)

val lift_for_contrast
  :  background:Masc_tui_terminal_palette.rgb
  -> floor:float
  -> Masc_tui_terminal_palette.rgb
  -> Masc_tui_terminal_palette.rgb
(** The colour, moved in lightness only until it clears [floor] against
    [background], and no further. A colour already clearing it is returned
    unchanged, so a theme that chose well is never overruled.

    Direction is away from the background: a dark terminal brightens, a light
    one darkens. Where the whole lightness range is not enough -- a theme that
    put a colour where no lightness of it can be read -- the end of the range
    is returned, which is still the most readable point there is. *)

val recede_toward
  :  background:Masc_tui_terminal_palette.rgb
  -> floor:float
  -> max_ratio:float
  -> Masc_tui_terminal_palette.rgb
  -> Masc_tui_terminal_palette.rgb option
(** The colour stepped toward [background] -- the opposite errand to
    {!lift_for_contrast} -- as far as [max_ratio] or the [floor] allows,
    whichever binds first. [None] where the colour does not clear the floor
    even before moving, because a row with no room to give away cannot recede
    and still be read. *)
