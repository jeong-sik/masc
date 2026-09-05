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

val recede
  :  theme_mode:Masc_tui_terminal_palette.theme_mode option
  -> Masc_tui_terminal_palette.t option
  -> string
(** What a row draws to sit behind the ones around it.

    [Sgr.dim] is SGR 2, and SGR 2 blends the foreground toward black. On a
    dark terminal that is a step toward the background and the row recedes.
    On a light one it is a step away, so the row meant to be quiet comes out
    darker than its neighbours and the page reads upside down
    (microsoft/terminal#16493). [Sgr.gray] is no safer: Solarized and its
    relatives remap the bright colours onto a grey ramp, so it answers to the
    theme rather than to the background.

    So this computes instead of naming: the terminal's own text stepped
    toward the terminal's own background, projected through what the process
    can emit.

    Without a palette the page may still have been reported on its own, by
    DECSET 996 or 2031, which a multiplexer passes through where it answers
    no OSC colour query. Where it says light, [Sgr.gray] recedes and
    [Sgr.dim] does not -- SGR 2 blends toward black, so on a light terminal
    it walks away from the page. Where it says dark, or says nothing,
    [Sgr.dim] is what every row drew before this existed and is right on a
    dark one. Disabled colours produce [""]. *)

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

  val gray : string

  val bright_red : string
  val bright_green : string
  val bright_yellow : string
  val bright_blue : string
  val bright_magenta : string
  val bright_cyan : string
  (** Terminal-native bright slots. These remain palette-relative instead of
      forcing a dark-theme RGB value onto an unknown terminal background. *)

  val background : Masc_tui_terminal_palette.projected_color option -> string
  (** Serialize a projected background as SGR [48;2] or [48;5]. [None] and
      disabled colours produce the empty string. This is the only raw
      projected-background serializer. *)

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
  val l : string
  val r : string
end

(** A row's own weight, for chrome that carries no reading of its own:
    Normal, Dim, or the single accent.

    These three are the vocabulary for the frame around content -- a border,
    a marker, a label. They are not a cap on how many colours a screen may
    hold. A colour that reports health, phase, or attention draws through
    {!status}; a colour that says what a piece of content *is* -- a keyword,
    a string, a number, a diff line -- draws through {!Syntax}. What every
    one of those has in common is a name: a renderer asks for the reading and
    the theme answers with a colour, so one remap moves every site and the
    readability lift applies. Picking an SGR code in a renderer is what this
    rules out, not the number of colours on the screen. *)
type tone = Normal | Dim | Accent

val tone : tone -> string
(** [Normal] is [""] — the terminal's own text needs no escape. *)

(** Semantic state colours — the only place red, yellow, and green mean
    anything. A fact about health, phase, or attention draws through these
    names, so one remap moves every reading at once. *)
type status = Ok | Warn | Bad | Info | Muted

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
  :  Masc_tui_terminal_palette.t option
  -> ansi_color
  -> string
(** The colour, made readable against the page it lands on.

    masc draws these out of the reader's own palette, so what they come out as
    is their theme's call -- and across twelve base16 schemes that call fails
    often enough to matter: yellow at 1.44:1 on default-light, bright black at
    1.69:1 on Nord. That is not a dimmer warning, it is a warning nobody sees.

    Where the terminal answered OSC 4 and its entry clears 4.5:1, the plain
    code goes out and the theme keeps its choice. Where it does not, the same
    colour is lifted in lightness alone until it does, so a red is still a
    red. Where the terminal said nothing -- a multiplexer, an emulator without
    the reply -- the plain code goes out, which is what every row drew before
    this existed. *)

val status : status -> string
(** The plain SGR code. What the reader's own theme puts in that palette
    entry; use {!status_readable} where the palette is known. *)

val status_readable : Masc_tui_terminal_palette.t option -> status -> string
(** The same colour, made readable against the page it lands on.

    A status colour is drawn out of the reader's palette, so what it comes out
    as is their theme's call -- and across twelve base16 schemes that call
    fails often enough to matter: yellow at 1.44:1 on default-light, bright
    black at 1.69:1 on Nord. That is not a dimmer warning, it is a warning
    nobody sees.

    Where the terminal answered OSC 4 and its entry clears 4.5:1, the plain
    code goes out and the theme keeps its choice. Where it does not, the same
    colour is lifted in lightness alone until it does, so a red is still a
    red. Where the terminal said nothing -- a multiplexer, an emulator without
    the reply -- the plain code goes out, which is what every row drew before
    this existed. *)

(** Test-only environment and projection fixtures. The R12 check in
    [scripts/check-ssot.sh] is the repository production boundary: code under
    [bin/] and [lib/] may not name this module outside its owner
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
    -> Masc_tui_terminal_palette.t option
    -> ansi_color
    -> string
  (** Pure capability/environment fixture for {!val:ansi_readable}, so a test
      can drive it without the process capability deciding the answer. *)

  val recede
    :  colors_enabled:bool
    -> dim:string
    -> gray:string
    -> theme_mode:Masc_tui_terminal_palette.theme_mode option
    -> project:
         (Masc_tui_terminal_palette.rgb
          -> Masc_tui_terminal_palette.projected_color option)
    -> Masc_tui_terminal_palette.t option
    -> string
  (** Pure capability/environment fixture for {!val:recede}. [dim] is the
      fallback the production token passes, so a test can tell the computed
      colour from the fallback without naming an escape. *)
end

val selection : string
(** [Sgr.reverse]; survives NO_COLOR by contract. *)

val border_focus : string

(** Content-syntax colours: "this word is green" is a diff or a code literal,
    not a reading of state, so it stays out of [status]. *)
module Syntax : sig
  val keyword : string
  val string_ : string

  val json_key : string
  val json_number : string
  val json_literal : string
  val json_punctuation : string
  (** The roles a served JSON payload is drawn through: an object's key, a
      number, [true]/[false]/[null], and the braces, brackets, colons and
      commas.

      Content, not state -- a yellow token says it is a number, not that
      something is healthy. Keys lead because a reader scanning a nested
      result is looking for a name; punctuation recedes because the
      indentation already carries the structure, and drawing the braces at
      full weight is what makes a document read as noise. Strings reuse
      {!string_}, which is the same reading a code fence gives them. *)

  val code_comment : string
  val code_number : string
  val code_type : string
  val code_span : string
  val link : string
  val rule : string
  (** The rest of what a fenced block and a chat row hold: a comment, a
      number, a type name, an inline [`span`], a link's text, and the
      horizontal rule that divides sections.

      Content, not state -- a slanted comment says it is a comment, not that
      anything is unwell. Named here for the same reason the keyword is: a
      renderer that picks the code itself is one the readability lift cannot
      reach, and there were ninety-odd of those before these names existed. *)

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
end

val strip_sgr : string -> string
(** The string with its SGR sequences removed. A row drawn as one
    reverse-video band cannot carry inner styles — the first inner reset
    would cut the band short — so the selected row folds its colours and
    the reverse is the emphasis. *)

(** The shared glyph vocabulary. Plain text — callers colour it. *)
module Glyph : sig
  val task_done : string       (* ● *)
  val task_active : string     (* ◐ *)
  val task_todo : string       (* ○ *)
  val task_cancelled : string  (* × *)

  val breadcrumb_sep : string  (* ▸ *)

  val priority : int -> string
  (** ["!!!"] / ["!!"] / ["!"] / [""] for priorities 1, 2, 3, and lower. *)

  val braille_spinner : int -> string
  (** 8-step live braille spinner: ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷ *)

  val equalizer_level : int -> string
  (** 8-level audio equalizer bars:   ▂ ▃ ▄ ▅ ▆ ▇ █ *)
end

val set_lift_enabled : bool -> unit
(** Whether a colour the scheme leaves under the readable floor is raised
    until it clears. On by default, which is what masc drew before the setting
    existed.

    Off sends the scheme's colour as it is. That is what ratatui, tcell and
    lipgloss do -- emit the code, let the terminal decide -- and it is what a
    reader on a high-contrast scheme wants, since for them the lift moves a
    colour their theme placed deliberately. The cost is that masc says some
    things with colour alone, and a scheme that leaves those dim stops saying
    them. Whose call that is, is the reason this is a setting. *)

val lift_is_enabled : unit -> bool
(** What {!set_lift_enabled} was last given.

    The theme screen reads this to label its last column. The count beside a
    scheme is the number of its colours under the readable floor, and that
    number means "lifted" under one setting and "left under the floor" under
    the other -- so the screen has to be able to ask which.

    Three changes have now moved this one binding, each correct on its own
    base and wrong once the others landed: #31212 added the setting with no
    reader, #31216 removed the reader-less export, #31218 added the reader,
    and #31227 and #31228 each restored the declaration. If it looks dead
    again, the thing that broke is the theme screen's last column, not this
    line. *)
