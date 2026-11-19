(** Colour and glyph tokens for the TUI — the one module that names and
    serializes them.

    Pure by construction: no terminal probing. Everything here is a string or
    a function of plain values, so the renderer and its tests link the same
    code. [Masc_tui_ansi] re-exports these under its historical names; new call
    sites use this module directly so a theme swap moves every screen at once. *)


val colors_enabled : bool
(** no-color.org: a non-empty NO_COLOR suppresses styling. Structure —
    borders, markers, reverse-video selection — stays, because it carries
    meaning colour only repeats. MASC_TUI_FORCE_COLOR=1 overrides for a
    pipeline that strips the variable it wants. Read once at start-up. *)

val style : string -> string
(** [style code] is [code] with colours enabled and [""] without. *)

val user_message_background : Masc_tui_terminal_palette.t option -> string
(** A low-contrast background derived from a known terminal palette and
    projected through the process stdout capability. Missing palette,
    disabled colours, and unsupported projection all produce [""]. *)

val side_pane_background : Masc_tui_terminal_palette.t option -> string
(** The ground a side pane sits on beside a surface: the same step off the
    page {!user_message_background} takes, so the two things set apart from
    the page are set apart by the same amount. Same fallbacks. A colour drawn
    on it is measured against it by passing [Side_pane] as its {!surface}. *)

(** The ground a colour is drawn on, which is the ground its contrast is
    measured against. [Page] is the terminal's own background. [Side_pane]
    is {!side_pane_background}: the Keeper roster, a list index beside a
    detail, the Activity pane. A colour lifted to clear the page by a hair
    is under the floor one step off it, so the caller names the ground. *)
type surface = Page | Side_pane

val sidebar_selection : Masc_tui_terminal_palette.t option -> string
(** A restrained neutral band derived from the terminal palette. Falls back
    to reverse video without a usable colour palette. Indexed colours use
    xterm defaults for projection, not observed slot values. *)

val selection_style : Masc_tui_terminal_palette.t option -> string
(** A Truecolor accent-tinted selection band derived from the active palette
    with a foreground verified to clear WCAG 4.5:1 over the tinted band, and
    the band itself separated from the page ground. Falls back to a neutral
    Truecolor step when the accent sits too close to the page, and to
    {!selection} (reverse video) when colour is disabled, the palette is
    absent, or stdout cannot emit direct 24-bit RGB. *)

val recede : surface:surface -> Masc_tui_terminal_palette.t option -> string
(** Secondary text is blended toward the palette background while the projected
    colour is estimated to retain 4.5:1 contrast against [surface]'s ground. For ANSI-256 the estimate
    uses xterm's default slot value, which the terminal may have changed.
    Otherwise retain the terminal's default foreground.
    Missing palette or unsupported colour depth also retains that foreground;
    SGR dim and an assumed grey cannot establish contrast. This changes only
    foreground, so callers must close an enclosing dim span before using it.
    Disabled colours produce [""] rather than a colour override. *)

val border_muted : surface:surface -> Masc_tui_terminal_palette.t option -> string
(** Non-text hairline colour for unfocused panel borders, card frames, and
    horizontal rules. On Truecolor terminals, steps the foreground further
    toward [surface]'s ground down to a 2.2:1 hairline floor so structural
    chrome sits behind secondary text instead of competing with it. Falls back
    to {!recede} on non-Truecolor capabilities and to [""] under NO_COLOR. *)

(** Raw SGR sequences. Renderers normally want the semantic names below;
    these exist for the [Masc_tui_ansi] shim and for content that really is
    about a colour (a diff background) rather than a reading of state. *)
module Sgr : sig
  val reset : string
  (** Unconditional even under NO_COLOR: reverse-video survives there, and
      this is what closes it. *)

  val bold : string
  val dim : string
  val underline : string
  val italic : string
  val no_italic : string
  val strike : string
  val no_strike : string
  (** Weight is not the only axis a terminal has, and drawing every
      distinction as a colour is what makes a screen loud without making it
      legible: emphasis slants, and a reading that has been withdrawn -- a
      dropped goal, a cancelled row -- is struck. Each closes to its own
      off-code rather than to a full reset, so a span inside a coloured row
      leaves that row's colour where it was. *)

  val no_underline : string
  (** SGR 24: close underline without resetting foreground, background, or
      weight. Conditional under NO_COLOR like the underline it closes. *)

  val black : string
  val red : string
  val green : string
  val yellow : string
  val blue : string
  val magenta : string
  val cyan : string
  val white : string

  val default_fg : string
  (** SGR 39: the terminal's own text colour. Unlike [reset] it leaves bold
      and dim alone, so it can sit inside an emphasised run. *)

  val default_bg : string
  (** SGR 49: the terminal's own page colour behind the next cells. A picture
      drawn in half blocks uses it where a pixel is transparent, so the page
      shows through instead of a guess at its colour. *)

  val gray : string

  val bright_red : string
  val bright_green : string
  val bright_yellow : string
  val bright_blue : string
  val bright_magenta : string
  val bright_cyan : string
  val bright_white : string
  (** Terminal-native bright slots. These remain palette-relative instead of
      forcing a dark-theme RGB value onto an unknown terminal background. *)

  val truecolor_foreground : r:int -> g:int -> b:int -> string
  val truecolor_background : r:int -> g:int -> b:int -> string
  (** Colour that came from a picture rather than from the theme: an image
      mosaic's pixels, a link preview's swatch. There is no palette to project
      through, so these take the channels directly -- but they are still
      serialized here, and still silenced when colour is off. Everything else
      passes a projected colour to {!background}. *)

  val background : Masc_tui_terminal_palette.projected_color option -> string
  (** Serialize a projected background as SGR [48;2] or [48;5]. [None] and
      disabled colours produce the empty string. This is the only raw
      projected-background serializer. *)

  val foreground : Masc_tui_terminal_palette.projected_color option -> string
  (** The same for a foreground, as SGR [38;2] or [38;5]: a colour some other
      program chose -- an official client's login screen -- projected for
      what this process's stdout can draw. *)

  val bg_removed : string
  val bg_added : string
  (** Diff-row backgrounds; 256-colour cube entries. *)

  val reverse : string
  (** Unconditional even under NO_COLOR: the one selection signal every
      terminal renders without colour. *)
end

(** Terminal control sequences that are not styling. *)
module Term : sig
  val clear : string
  val hide_cursor : string
  val show_cursor : string
  val move_to : int -> int -> string
end

(** Box-drawing characters (UTF-8). *)
module Box : sig
  val h : string
  val v : string
  val tl : string
  val tr : string
  val bl : string
  val br : string
  val tl_round : string
  val tr_round : string
  val bl_round : string
  val br_round : string
  val h_heavy : string
  val v_heavy : string
  val tl_heavy : string
  val tr_heavy : string
  val bl_heavy : string
  val br_heavy : string
  val scroll_up : string
  val scroll_down : string
  val scroll_thumb : string
  val l : string
  val r : string
end

(** Semantic state colours — the only place red, yellow, and green mean
    anything. A fact about health, phase, or attention draws through these
    names, so one remap moves every reading at once. *)
type status = Ok | Warn | Bad | Info | Muted

(** How many colours the terminal draws, which is what decides how a meter
    against a declared limit colours its cells (RFC tui-one-screen-grammar
    section 7.3). *)
type color_depth =
  | No_color  (** Colours are off: the meter draws its glyphs alone. *)
  | Colors_16  (** The palette's sixteen entries, one per band. *)
  | Colors_256  (** A colour between the bands, from the 256-colour cube. *)
  | Truecolor  (** A colour between the bands, as 24-bit RGB. *)

val color_depth : unit -> color_depth
(** This process's depth: [No_color] when {!colors_enabled} is false,
    otherwise the stdout capability. A capability the terminal does not state
    draws sixteen colours, which is what every other colour here sends it. *)

(** Where a cell sits against a declared limit. Each band draws in one status
    colour: success, warning, danger. *)
type limit_band =
  | Near_zero  (** Under half the limit: [Ok]. *)
  | Midway  (** Under four fifths of the limit: [Warn]. *)
  | Near_limit  (** The rest, up to the limit: [Bad]. *)

(** The colour one filled meter cell draws in. *)
type meter_cell_colour =
  | Cell_plain
      (** No colour of its own: the glyph takes the colour around it. *)
  | Cell_band of limit_band  (** The band's status colour. *)
  | Cell_blend of { band : limit_band; position : float }
      (** A colour between success, warning and danger at [position], the
          cell's reach as a share of the limit in [[0, 1]]. [band] is what the
          cell draws when the blend cannot be drawn. *)

val limit_cell_colour :
  depth:color_depth ->
  index:int ->
  width:int ->
  value:int ->
  limit:int ->
  meter_cell_colour
(** The colour cell [index] (from 0) of a [width]-cell meter takes when the
    meter draws [value] against a declared [limit]. The cell reaches the
    smaller of its far edge, [(index + 1) / width], and [value / limit]
    ([value] clamped into [[0, limit]]), so a cell the value only enters, or
    the one cell a small value is rounded up to, takes the value's band. Under
    one half is [Near_zero], under four fifths [Midway], the rest
    [Near_limit]. [No_color] draws [Cell_plain], [Colors_16] the band,
    [Colors_256] and [Truecolor] a blend. *)

(** What a picture (meter, graph) needs to draw its colours: the terminal's
    depth, and the ground and palette its colours are measured against. *)
type paint = {
  depth : color_depth;
  surface : surface;
  palette : Masc_tui_terminal_palette.t option;
}

(** The ANSI colours masc names. Only the ones something draws a meaning
    through: a colour absent here is one nothing reads a meaning out of. *)
type ansi_color =
  | Bright_red
  | Bright_green
  | Bright_yellow
  | Bright_blue
  | Bright_magenta
  | Bright_cyan
  | Bright_black

val ansi_readable
  :  surface:surface
  -> Masc_tui_terminal_palette.t option
  -> ansi_color
  -> string
(** The colour, adjusted toward readability against [surface]'s ground.

    masc draws these out of the reader's own palette, so what they come out as
    is their theme's call -- and across twelve base16 schemes that call fails
    often enough to matter: yellow at 1.44:1 on default-light, bright black at
    1.69:1 on Nord. That is not a dimmer warning, it is a warning nobody sees.

    Where the terminal answered OSC 4 and its entry clears 4.5:1, the plain
    code goes out and the theme keeps its choice. Where it does not, the same
    colour is lifted in lightness toward the floor before projection. An
    indexed projection uses an unobserved slot and cannot guarantee contrast.
    Where the terminal said nothing -- a multiplexer, an emulator without
    the reply -- the plain code goes out, which is what every row drew before
    this existed. *)

val status : status -> string
(** The plain SGR code. What the reader's own theme puts in that palette
    entry; use {!status_readable} where the palette is known. *)

val status_readable
  :  surface:surface
  -> Masc_tui_terminal_palette.t option
  -> status
  -> string
(** The same colour, adjusted toward readability against [surface]'s ground.

    A status colour is drawn out of the reader's palette, so what it comes out
    as is their theme's call -- and across twelve base16 schemes that call
    fails often enough to matter: yellow at 1.44:1 on default-light, bright
    black at 1.69:1 on Nord. That is not a dimmer warning, it is a warning
    nobody sees.

    Where the terminal answered OSC 4 and its entry clears 4.5:1, the plain
    code goes out and the theme keeps its choice. Where it does not, the same
    colour is lifted in lightness toward the floor before projection. An
    indexed projection uses an unobserved slot and cannot guarantee contrast.
    Where the terminal said nothing -- a multiplexer, an emulator without
    the reply -- the plain code goes out, which is what every row drew before
    this existed. *)

val status_text_readable
  :  surface:surface
  -> Masc_tui_terminal_palette.t option
  -> status
  -> string
(** For text that names its own status, use the terminal's default foreground
    when a palette entry is unknown or a projected colour cannot be verified
    above the text contrast floor against [surface]'s ground. This fallback cannot guarantee readability
    if the terminal's own foreground is low-contrast. Preserve the original
    ANSI colour when the reader has explicitly disabled
    colour lifting. Colour-only distinctions continue to use {!status_readable}. *)

val meter_cell_readable : paint -> meter_cell_colour -> string
(** The SGR a meter cell draws before its glyph. [Cell_plain] is [""].
    [Cell_band] is the band's status colour through {!status_readable}.
    [Cell_blend] is an Oklab interpolation of the palette's success, warning
    and danger entries, lifted against the paint's ground to clear 4.5:1 and
    projected through [best_color]. It draws the band's colour instead when no
    palette is reported, lifting is off, or the projection misses the floor.
    Under [NO_COLOR] every cell is [""]. *)

(** {1 Picture ramps}

    Every filled meter cell and every graph dot that is not against a
    declared limit takes a colour from its series' ramp, the way btop paints
    its memory and network boxes (RFC tui-one-screen-grammar section 7.3). The
    position on the ramp is the cell's reach along the bar, or the dot's
    height in the graph, in [[0, 1]]. *)

(** The quantity a picture draws. One quantity draws in one hue on every
    screen, so a reader who learned its colour once finds it again. *)
type series =
  | Calls  (** Tool calls, requests: how much ran. Blue (cyan is reserved for status.info). *)
  | Failures
      (** Failed calls. Magenta: red is the status colour of a bucket in which
          every call failed, and a legend says so. *)
  | Latency  (** p95 and other waits. Yellow. *)
  | Memory  (** Heap words, memory facts. Magenta. *)
  | Completion  (** Done against a total, finished per day. Green. *)
  | Capacity  (** Running against bootable, capacity against a target. Blue. *)
  | Backlog  (** Work behind: a lag, a queue. Yellow. *)
  | Usage  (** A plan window's use over days, its role unconfirmed. Blue. *)
  | Wakes
      (** Scheduled Keeper wakes per half hour ahead. Green (cyan is reserved
          for status.info). *)

val ramp_steps : int
(** [100]: a ramp is drawn as [ramp_steps + 1] colours, like btop's 101. *)

val ramp_reader : paint -> series -> position:float -> string
(** [ramp_reader paint series] finds the ramp's table once and returns the
    reader of its steps, for a drawing that colours many cells: each
    [~position] is then one array read. The colours are {!ramp_style}'s. *)

val ramp_style : paint -> series -> position:float -> string
(** The SGR a cell at [position] on [series]' ramp draws before its glyph.
    [position] is clamped into [[0, 1]] and [nan] is [0]; the colour is the
    ramp's step at or below it. Under [No_color] it is [""].

    With a reported palette, at 256 colours or truecolor and lifting on, the
    ramp interpolates in Oklab from the hue stepped toward the ground, clearing
    3:1 (a graphical object), to the palette's bright entry of that hue lifted
    to clear 4.5:1, so every hue spans at least that band. A ramp is blended
    whole or not at all: where any step cannot be drawn above the floor -- or
    at sixteen colours, with no palette, with lifting off -- every step is the
    hue's bright code.

    The colours of one ramp are computed once per palette, depth, ground and
    lift switch and then read from a table. *)

(** Semantic panel border accent (btop-style per-box border hue). Under
    truecolor/256-colour with a probed palette, each non-neutral role draws in
    the deep WCAG-3:1 stop of its corresponding series hue; under 16-colour or
    unknown palette it falls back to {!recede}, and under {!No_color} to [""]. *)
type panel_role =
  | Panel_neutral
  | Panel_fleet
  | Panel_usage
  | Panel_memory
  | Panel_attention

val panel_border : paint -> panel_role -> string

(** Test-only environment and projection fixtures. Code under [bin/] and
    [lib/] may not name this module outside its owner
    implementation/interface. Production callers use the semantic tokens
    below. *)
module For_testing : sig
  val colors_enabled
    :  force_color:string option
    -> no_color:string option
    -> bool
  (** Pure environment-policy fixture. Only [force_color = Some "1"]
      overrides a non-empty [no_color]. *)

  val user_message_background_rgb
    :  Masc_tui_terminal_palette.rgb
    -> Masc_tui_terminal_palette.rgb
  (** Pure low-contrast blend derived from the terminal's default background.
      Light backgrounds blend 4 percent toward black; dark backgrounds blend
      12 percent toward white. *)

  val user_message_background
    :  colors_enabled:bool
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> Masc_tui_terminal_palette.t option
    -> string
  (** Pure capability/environment fixture for the production semantic token. *)

  val side_pane_background
    :  colors_enabled:bool
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> Masc_tui_terminal_palette.t option
    -> string
  (** Capability fixture for {!val:side_pane_background}: the ground bytes a
      side pane draws, so a test measures a colour against what is behind it. *)

  val recede_rgb
    :  foreground:Masc_tui_terminal_palette.rgb
    -> background:Masc_tui_terminal_palette.rgb
    -> Masc_tui_terminal_palette.rgb option
  (** Pure blend: the terminal's text stepped toward its background, as far as
      the contrast floor allows and no further. Direction comes from the two
      colours, so it darkens on a light terminal and lightens on a dark one.
      [None] where the text is already under the floor and has no room to
      give. *)

  val ansi_color_index : ansi_color -> int
  (** Which of the sixteen palette entries a colour is -- the same decision
      the SGR code makes, as an index, so a test can look up what the reader's
      theme actually put there. *)

  val ansi_color_code : ansi_color -> string
  (** The plain SGR code, conditional on colours as everything else is. *)

  val ansi_readable
    :  colors_enabled:bool
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> surface:surface
    -> Masc_tui_terminal_palette.t option
    -> ansi_color
    -> string
  (** Pure capability/environment fixture for {!val:ansi_readable}, so a test
      can drive it without the process capability deciding the answer. *)

  val status_text_readable
    :  colors_enabled:bool
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> surface:surface
    -> Masc_tui_terminal_palette.t option
    -> status
    -> string
  (** Capability fixture for {!val:status_text_readable}. *)

  val ramp_style
    :  colors_enabled:bool
    -> project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option)
    -> paint
    -> series
    -> position:float
    -> string
  (** {!ramp_style} without the table, with the colour switch and projection
      given. *)

  val meter_cell_readable
    :  colors_enabled:bool
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> paint
    -> meter_cell_colour
    -> string
  (** Capability fixture for {!val:meter_cell_readable}. *)

  val recede
    :  colors_enabled:bool
    -> default_foreground:string
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> surface:surface
    -> Masc_tui_terminal_palette.t option
    -> string
  (** Pure capability/environment fixture for {!val:recede}. *)

  val selection_style
    :  colors_enabled:bool
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> Masc_tui_terminal_palette.t option
    -> string
  (** Pure capability/environment fixture for {!val:selection_style}. *)

  val border_muted_rgb
    :  foreground:Masc_tui_terminal_palette.rgb
    -> background:Masc_tui_terminal_palette.rgb
    -> Masc_tui_terminal_palette.rgb option
  (** Pure hairline blend: foreground stepped further toward background down
      to the 2.2:1 non-text border floor. *)

  val border_muted
    :  colors_enabled:bool
    -> default_foreground:string
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> surface:surface
    -> Masc_tui_terminal_palette.t option
    -> string
  (** Pure capability/environment fixture for {!val:border_muted}. *)

  val diff_row_styles
    :  colors_enabled:bool
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> kind:[ `Added | `Removed ]
    -> Masc_tui_terminal_palette.t option
    -> string * string
  (** Pure capability/environment fixture returning [(bg, fg)] SGR escapes for
      a diff row. *)
end

val selection : string
(** [Sgr.reverse]; survives NO_COLOR by contract. *)

(** Content colours that stay constant: "this word is green" is a diff or a
    code literal, not a reading of state, so it stays out of [status]. The
    words a reader scans for (keyword, string, number, type, link, a JSON key)
    are hues of the palette and draw through [Masc_tui_ansi.Theme.Syntax],
    which lifts them. *)
module Syntax : sig
  val json_punctuation : string
  (** The braces, brackets, colons and commas of a served JSON payload.

      Content, not state. Punctuation recedes because the indentation already
      carries the structure, and drawing the braces at full weight is what
      makes a document read as noise. *)

  val diff_added : string
  val diff_removed : string
  (** Diff colours in the foreground, for compact readings that do not paint
      a whole row. *)

  val diff_added_bg : string
  val diff_removed_bg : string
  (** Diff-row backgrounds.

      Content rather than state, the same way a keyword is: a green line says
      the file gained it, not that something is healthy. Both dedicated diff
      surfaces and changed rows inside a chat fence ask for these instead of
      reaching into {!Sgr}, so one remap moves every full-row diff at once. *)

  val diff_row_foreground : string
  (** Fixed light text paired with both fixed dark diff backgrounds. Unlike
      the terminal default foreground, this pair keeps its contrast when a
      light terminal theme uses dark default text. *)

  val diff_row_styles
    :  kind:[ `Added | `Removed ]
    -> Masc_tui_terminal_palette.t option
    -> string * string
  (** Palette-adaptive Truecolor [(bg, fg)] escapes for diff rows. Blends the
      active page ground toward green (added) or red (removed) on Truecolor
      terminals and lifts the foreground to clear WCAG 4.5:1 over the tinted
      background. Falls back to [(diff_added_bg/diff_removed_bg,
      diff_row_foreground)] on non-Truecolor capabilities and [("", "")] under
      NO_COLOR. *)
end

val strip_sgr : string -> string
(** The string with its SGR sequences removed. A row drawn as one
    reverse-video band cannot carry inner styles — the first inner reset
    would cut the band short — so the selected row folds its colours and
    the reverse is the emphasis. Text with no SGR opener reuses its original
    string; ordinary byte spans are preserved verbatim. *)

(** The shared glyph vocabulary. Plain text — callers colour it. *)
module Glyph : sig
  val progress_waiting : string  (* ○ *)
  val progress_active : string   (* ◐ *)
  val progress_done : string     (* ● *)
  val progress_ended : string    (* × *)
  (** How far a piece of work has got. Task rows, the Backlog counts and the
      Goal counters read these, so one mark means one stage on a screen. *)

  val current_entry : string  (* ▸ *)
  (** Where you are, on a strip of places you could be: the surface strip's
      active surface and the keeper detail screen's active tab. *)

  val no_value : string  (* — *)
  (** What a field with no value draws, where the surface measures in display
      cells. A row and the detail pane behind it read the same field, so they
      draw the same mark for its absence.

      A byte-padded column and a one-cell glyph alphabet keep their own mark;
      the implementation says why. *)

  val priority : int -> string
  (** ["!"] when the priority number is 1 or lower, the top priority, and an
      empty string for the rest. *)
end

val set_lift_enabled : bool -> unit
(** Whether to try raising a colour the scheme leaves under the readable
    floor. Output capability can prevent a verified lift. On by default.

    Off sends the scheme's colour as it is. That is what ratatui, tcell and
    lipgloss do -- emit the code, let the terminal decide -- and it is what a
    reader on a high-contrast scheme wants, since for them the lift moves a
    colour their theme placed deliberately. The cost is that masc says some
    things with colour alone, and a scheme that leaves those dim stops saying
    them. Whose call that is, is the reason this is a setting. *)

val lift_is_enabled : unit -> bool
(** What {!set_lift_enabled} was last given; used to invalidate cached
    colours when the setting changes. *)

val set_direct_truecolor : bool -> unit
(** When enabled on a Truecolor stdout with an active palette, semantic
    colours emit their 24-bit RGB escape sequences ([38;2;r;g;b]) directly
    instead of falling back to plain 16-colour ANSI SGR codes when an entry
    clears the readability floor. Enabled when an explicit TUI theme is active
    and disabled when following the terminal's own ANSI slots. *)

val direct_truecolor_is_enabled : unit -> bool
(** What {!set_direct_truecolor} was last given; used to invalidate cached
    colours when switching between an explicit theme and terminal-follow mode. *)

val strip_sgr_with_positions : string -> string * int array
(** The same SGR stripping grammar as {!strip_sgr}, retaining each copied
    byte's original input offset for semantic source-map composition. *)
