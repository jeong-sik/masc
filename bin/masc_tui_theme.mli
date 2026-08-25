(** Colour and glyph tokens for the TUI — the one module that names and
    serializes them.

    Pure by construction: no terminal probing. Everything here is a string or
    a function of plain values, so the renderer and its tests link the same
    code. [Masc_tui_ansi] re-exports these under its historical names; new call
    sites use this module directly so a theme swap moves every screen at once. *)

module For_testing : sig
  val colors_enabled
    :  force_color:string option
    -> no_color:string option
    -> bool
  (** Pure environment-policy fixture. Only [force_color = Some "1"]
      overrides a non-empty [no_color]. *)
end

val colors_enabled : bool
(** no-color.org: a non-empty NO_COLOR suppresses styling. Structure —
    borders, markers, reverse-video selection — stays, because it carries
    meaning colour only repeats. MASC_TUI_FORCE_COLOR=1 overrides for a
    pipeline that strips the variable it wants. Read once at start-up. *)

val style : string -> string
(** [style code] is [code] with colours enabled and [""] without. *)

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

(** The 3-tone rule: a row is Normal, Dim, or the single accent colour.
    Anything outside these three is a claim about state and belongs to
    [status] instead. *)
type tone = Normal | Dim | Accent

val tone : tone -> string
(** [Normal] is [""] — the terminal's own text needs no escape. *)

(** Semantic state colours — the only place red, yellow, and green mean
    anything. A fact about health, phase, or attention draws through these
    names, so one remap moves every reading at once. *)
type status = Ok | Warn | Bad | Info | Muted

val status : status -> string

val selection : string
(** [Sgr.reverse]; survives NO_COLOR by contract. *)

val border_focus : string

(** Content-syntax colours: "this word is green" is a diff or a code literal,
    not a reading of state, so it stays out of [status]. *)
module Syntax : sig
  val keyword : string
  val string_ : string

  val diff_added_bg : string
  val diff_removed_bg : string
  (** Diff-row backgrounds.

      Content rather than state, the same way a keyword is: a green line says
      the file gained it, not that something is healthy. A renderer asks for
      these instead of reaching into {!Sgr}, so one remap moves every diff at
      once. *)
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
end
